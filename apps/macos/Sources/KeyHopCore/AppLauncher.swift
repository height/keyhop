import AppKit
import CryptoKit
import Darwin
import Foundation

public enum ShellCommand {
    /// Single-quoted POSIX shell words preserve every argument, including quotes,
    /// dollar signs, backticks, whitespace and newlines, without evaluation.
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func terminalScript(helper: String, root: String, requestID: String) -> String {
        "#!/bin/sh\nexport KEYHOP_HOME=\(quote(root))\nexec \(quote(helper)) --run-cli \(quote(requestID))\n"
    }
}

@MainActor
public final class AppLauncher {
    private let store: ConfigStore
    private let helperExecutableURL: URL
    private let existingInstanceCheck: ((AppProfile) throws -> Bool)?
    private let existingApplicationActivator: ((AppProfile) throws -> Int?)?
    private let launchedApplicationActivator: ((Int) async -> Bool)?
    private let checker: ProxyChecker
    public private(set) var lastProxyCheck: ProxyCheckResult?

    /// The optional activator returns the PID of an activated GUI app, nil when
    /// no matching app exists, and throws if activation fails.
    public init(store: ConfigStore, helperExecutableURL: URL = Bundle.main.executableURL!, checker: ProxyChecker = ProxyChecker(), existingInstanceCheck: ((AppProfile) throws -> Bool)? = nil, existingApplicationActivator: ((AppProfile) throws -> Int?)? = nil, launchedApplicationActivator: ((Int) async -> Bool)? = nil) {
        self.store = store; self.helperExecutableURL = helperExecutableURL; self.checker = checker; self.existingInstanceCheck = existingInstanceCheck
        self.existingApplicationActivator = existingApplicationActivator
        self.launchedApplicationActivator = launchedApplicationActivator
    }
    public static func processRunning(_ profile: AppProfile) throws -> Bool {
        if profile.kind == .gui { return runningApplication(profile) != nil }
        return try CLIHelper.processRunning(profile)
    }
    private static func runningApplication(_ profile: AppProfile) -> NSRunningApplication? {
        let requested = URL(fileURLWithPath: profile.path).resolvingSymlinksInPath().standardizedFileURL
        let bundleID = Bundle(url: requested)?.bundleIdentifier ?? profile.bundleIdentifier
        return NSWorkspace.shared.runningApplications.first { app in
            guard !app.isTerminated else { return false }
            if let bundleID, app.bundleIdentifier == bundleID { return true }
            return app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == requested
        }
    }
    private func alreadyRunning(_ profile: AppProfile) throws -> Bool {
        try existingInstanceCheck?(profile) ?? Self.processRunning(profile)
    }
    private func activateExistingApplication(_ profile: AppProfile) throws -> Int? {
        if let existingApplicationActivator { return try existingApplicationActivator(profile) }
        guard let application = Self.runningApplication(profile) else { return nil }
        guard application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) else {
            throw LauncherError.operation("无法将 \(profile.name) 切换到前台。App 仍在运行，未重新启动或更改其代理配置。")
        }
        return Int(application.processIdentifier)
    }
    private func activatedRecord(_ profile: AppProfile, pid: Int, proxyEnabled: Bool) -> LaunchRecord {
        let message = "已唤起 \(profile.name)。" + (proxyEnabled ? "现有进程的代理配置保持不变，流量未验证；如需应用新代理，请先自行退出再打开。" : "")
        return record(profile, .activated, message, pid: pid)
    }
    /// Open a configured app, or bring its existing process to the foreground.
    /// Activation does not apply proxy settings and is never reported as a new
    /// proxied launch. A cold launch retains all of launch's proxy checks.
    public func summon(configuration: LauncherConfiguration, profile: AppProfile) async -> LaunchRecord {
        lastProxyCheck = nil
        do {
            try profile.validate()
            if profile.kind == .gui, let pid = try activateExistingApplication(profile) {
                return activatedRecord(profile, pid: pid, proxyEnabled: configuration.proxy.enabled)
            }
            let result = await launch(configuration: configuration, profile: profile)
            if result.state == .alreadyRunning {
                // The app may have opened while the launch path was checking
                // the proxy. Foreground it without creating another process.
                if profile.kind == .gui, let pid = try activateExistingApplication(profile) {
                    return activatedRecord(profile, pid: pid, proxyEnabled: configuration.proxy.enabled)
                }
                if profile.kind == .cli {
                    return record(profile, .alreadyRunning, "CLI 已运行，请切换到现有终端。" + (configuration.proxy.enabled ? "如需应用新代理，请先自行退出再打开。" : ""))
                }
            }
            return await foregroundNewGUI(result, profile: profile)
        } catch {
            return record(profile, .failed, error.localizedDescription)
        }
    }
    /// Only the PID just returned by launch may be foregrounded here. Looking
    /// the app up by its profile could select an unrelated existing instance.
    func foregroundNewGUI(_ result: LaunchRecord, profile: AppProfile) async -> LaunchRecord {
        guard profile.kind == .gui, result.state == .launched, let pid = result.pid else { return result }
        let foregrounded: Bool
        if let launchedApplicationActivator { foregrounded = await launchedApplicationActivator(pid) }
        else { foregrounded = await Self.foregroundApplication(pid: pid) }
        var updated = result
        updated.message += foregrounded ? " App 已切换到前台。" : " 未确认切换到前台，请手动打开窗口。"
        return updated
    }
    private static func foregroundApplication(pid: Int) async -> Bool {
        guard let processID = pid_t(exactly: pid), processID > 0 else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(1500))
        while clock.now < deadline, !Task.isCancelled {
            if let application = NSRunningApplication(processIdentifier: processID) {
                if application.isTerminated { return false }
                if application.isFinishedLaunching,
                   application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) { return true }
            }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return false }
        }
        return false
    }
    public func launch(configuration: LauncherConfiguration, profile: AppProfile) async -> LaunchRecord {
        lastProxyCheck = nil
        let appliedProxy = configuration.proxy.enabled ? configuration.proxy : nil
        do {
            try configuration.validate(); try profile.validate()
            if try alreadyRunning(profile) { return record(profile, .alreadyRunning, "\(profile.name) 已运行。请先自行退出，再从此处重新启动；不会自动结束任何进程。") }
            let executable = try Self.executableURL(profile)
            if let appliedProxy {
                let proxy = await checker.check(appliedProxy)
                lastProxyCheck = proxy
                guard proxy.available else { return record(profile, .proxyUnavailable, "未启动：\(proxy.message)", proxy: appliedProxy) }
                // The probe awaited network IO. Recheck to close the ordinary
                // race where a user opens the app while it is in progress.
                if try alreadyRunning(profile) { return record(profile, .alreadyRunning, "\(profile.name) 已在检查期间启动。请先自行退出，再重新启动。") }
            }
            if profile.kind == .cli { return try requestCLI(configuration: configuration, profile: profile) }
            let logs = store.rootURL.appendingPathComponent("logs", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let logURL = logs.appendingPathComponent("\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: logURL)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = profile.launchArguments(proxy: configuration.proxy)
            process.environment = configuration.proxy.environment()
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
            try process.run()
            try? await Task.sleep(for: .milliseconds(250))
            guard process.isRunning else {
                return record(profile, .failed, "启动进程已退出（状态 \(process.terminationStatus)）。未确认 App 持续运行；日志：\(logURL.path)", proxy: appliedProxy)
            }
            let message = appliedProxy == nil ? "已启动 \(profile.name)。" : "已创建进程并传入代理配置；尚未验证目标 App 流量。"
            return record(profile, .launched, message, pid: Int(process.processIdentifier), proxy: appliedProxy)
        } catch {
            return record(profile, .failed, error.localizedDescription, proxy: appliedProxy)
        }
    }
    private func requestCLI(configuration: LauncherConfiguration, profile: AppProfile) throws -> LaunchRecord {
        let requestID = UUID().uuidString
        let request = CLILaunchRequest(id: requestID, createdAt: Date(), configuration: configuration, profile: profile)
        try store.saveRequest(request)
        let scriptURL = store.requestsURL.appendingPathComponent("\(requestID).command")
        let script = ShellCommand.terminalScript(helper: helperExecutableURL.path, root: store.rootURL.path, requestID: requestID)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let opener = Process(); opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-a", "Terminal", scriptURL.path]
        opener.standardOutput = FileHandle.nullDevice; opener.standardError = FileHandle.nullDevice
        try opener.run(); opener.waitUntilExit()
        guard opener.terminationStatus == 0 else { throw LauncherError.operation("无法打开 Terminal，CLI 未确认启动。") }
        return LaunchRecord(profileID: profile.id, state: .requested, message: "已请求 Terminal 启动；等待实际进程回执。CLI 运行中检测为尽力检查。", requestID: requestID, proxy: configuration.proxy.enabled ? configuration.proxy : nil)
    }
    private func record(_ profile: AppProfile, _ state: LaunchState, _ message: String, pid: Int? = nil, proxy: ProxyConfiguration? = nil) -> LaunchRecord {
        LaunchRecord(profileID: profile.id, state: state, message: message, pid: pid, proxy: proxy)
    }
    public static func executableURL(_ profile: AppProfile) throws -> URL {
        let path = URL(fileURLWithPath: profile.path)
        let executable: URL
        if profile.kind == .gui {
            guard let bundle = Bundle(url: path), let executableURL = bundle.executableURL else { throw LauncherError.operation("找不到有效的 App：\(profile.path)。请编辑路径。") }
            if let expected = profile.bundleIdentifier, let actual = bundle.bundleIdentifier, expected != actual {
                throw LauncherError.operation("App 的实际标识为 \(actual)，与配置的 \(expected) 不同。请重新选择 App。")
            }
            executable = executableURL
        } else { executable = path }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw LauncherError.operation("找不到可执行文件：\(executable.path)。请编辑路径。") }
        return executable
    }
}

public enum CLIHelper {
    public static func processRunning(_ profile: AppProfile) throws -> Bool {
        let process = Process(); let output = Pipe(); let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps"); process.arguments = ["-axo", "pid=,command="]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LauncherError.operation("无法读取进程列表，不能确认 CLI 是否已运行；为避免重复实例，本次未启动。") }
        let paths = Set([profile.path, URL(fileURLWithPath: profile.path).resolvingSymlinksInPath().path])
        let ownPID = Int(getpid())
        return String(decoding: data, as: UTF8.self).split(separator: "\n").contains { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int(parts[0]), pid != ownPID else { return false }
            let command = String(parts[1])
            let commandTokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
            let serviceModes = ["app-server", "mcp-server"]
            if URL(fileURLWithPath: profile.path).lastPathComponent == "codex",
               commandTokens.count >= 2, serviceModes.contains(commandTokens[1]),
               !serviceModes.contains(profile.arguments.first ?? "") { return false }
            for path in paths {
                if command == path || command.hasPrefix(path + " ") { return true }
                // npm-installed commands may run under node/python/shell. Limit
                // this match to an interpreter's first script argument.
                let tokens = command.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
                if tokens.count >= 2, ["node", "nodejs", "python", "python3", "bash", "sh", "zsh"].contains(URL(fileURLWithPath: tokens[0]).lastPathComponent), tokens[1] == path { return true }
            }
            // Codex's npm wrapper replaces itself with a platform binary. Its
            // exact basename is the only useful best-effort identity afterward.
            let first = command.split(maxSplits: 1, whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            return URL(fileURLWithPath: profile.path).lastPathComponent == "codex" && URL(fileURLWithPath: first).lastPathComponent == "codex"
        }
    }
    /// Called by the executable before creating NSApplication or taking the
    /// menu-bar singleton lock. Separate receipts avoid status.json write races.
    public static func run(requestID: String, store: ConfigStore) -> Int32 {
        var profileID = "unknown"
        var proxy: ProxyConfiguration?
        var claimedRequest = false
        func save(_ state: LaunchState, _ message: String, pid: Int? = nil) {
            let record = LaunchRecord(profileID: profileID, state: state, message: message, pid: pid, requestID: requestID, proxy: proxy)
            try? store.saveReceipt(record, requestID: requestID)
            if state != .launched { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        }
        do {
            let requestURL = try store.requestURL(requestID)
            let request = try store.loadRequest(requestID)
            profileID = request.profile.id; proxy = request.configuration.proxy.enabled ? request.configuration.proxy : nil
            guard request.id == requestID, request.profile.kind == .cli, abs(request.createdAt.timeIntervalSinceNow) < 300 else { throw LauncherError.operation("CLI 启动请求已过期或无效，请从菜单重新启动。") }
            // Atomic claim makes repeated Terminal opens of one script harmless.
            try FileManager.default.moveItem(at: requestURL, to: requestURL.appendingPathExtension("claimed"))
            claimedRequest = true
            defer {
                try? FileManager.default.removeItem(at: requestURL.appendingPathExtension("claimed"))
                try? FileManager.default.removeItem(at: store.requestsURL.appendingPathComponent("\(requestID).command"))
            }
            try request.configuration.validate(); try request.profile.validate()
            let executableIdentity = URL(fileURLWithPath: request.profile.path).resolvingSymlinksInPath().standardizedFileURL.path
            let lockName = SHA256.hash(data: Data(executableIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
            let lockURL = store.requestsURL.appendingPathComponent("cli-\(lockName).lock")
            let lockFD = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lockFD >= 0 else { throw LauncherError.operation("无法创建 CLI 实例锁，未启动。") }
            defer { flock(lockFD, LOCK_UN); close(lockFD) }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { save(.alreadyRunning, "这个 CLI 的启动请求或进程仍在运行，请先退出现有实例。"); return 1 }
            if try processRunning(request.profile) { save(.alreadyRunning, "CLI 已运行，请先自行退出再重新启动。运行中检测为尽力检查。"); return 1 }
            if let proxy {
                let check = ProxyChecker().checkSynchronously(proxy)
                guard check.available else { save(.proxyUnavailable, "CLI 未启动：\(check.message)"); return 1 }
                if try processRunning(request.profile) { save(.alreadyRunning, "CLI 已在检查期间启动，请先自行退出。"); return 1 }
            }
            guard FileManager.default.isExecutableFile(atPath: request.profile.path) else { throw LauncherError.operation("CLI 路径不可执行：\(request.profile.path)") }
            let process = Process(); process.executableURL = URL(fileURLWithPath: request.profile.path)
            process.arguments = request.profile.arguments
            var environment = request.configuration.proxy.environment()
            if let path = request.launchPath { environment["PATH"] = path }
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.standardInput; process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
            try process.run()
            // Foundation gives spawned processes their own process group. Hand
            // the controlling terminal to this child so interactive CLIs can
            // read keys and receive Ctrl-C rather than stopping on SIGTTIN.
            let originalForeground = tcgetpgrp(STDIN_FILENO)
            let previousTTOU = signal(SIGTTOU, SIG_IGN)
            if originalForeground >= 0 {
                if tcsetpgrp(STDIN_FILENO, process.processIdentifier) == 0 { kill(process.processIdentifier, SIGCONT) }
            }
            defer {
                if originalForeground >= 0 { _ = tcsetpgrp(STDIN_FILENO, originalForeground) }
                _ = signal(SIGTTOU, previousTTOU)
            }
            save(.launched, proxy == nil ? "CLI 已启动。" : "CLI 进程已创建并传入代理环境变量；目标流量未验证。", pid: Int(process.processIdentifier))
            process.waitUntilExit()
            save(.exited, "CLI 已退出（状态 \(process.terminationStatus)）。" + (proxy == nil ? "" : "目标流量未验证。"), pid: Int(process.processIdentifier))
            return process.terminationStatus
        } catch {
            if !claimedRequest,
               let requestURL = try? store.requestURL(requestID),
               let receiptURL = try? store.receiptURL(requestID),
               FileManager.default.fileExists(atPath: requestURL.appendingPathExtension("claimed").path) || FileManager.default.fileExists(atPath: receiptURL.path) {
                // Another helper owns this request or has already completed it.
                // Do not overwrite its actual lifecycle receipt with a failure.
                return 1
            }
            save(.failed, error.localizedDescription)
            return 1
        }
    }
}
