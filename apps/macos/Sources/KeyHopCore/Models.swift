import AppKit
import Darwin
import Foundation

public enum ProxyProtocol: String, Codable, CaseIterable, Sendable { case http, socks5 }
public enum AppKind: String, Codable, CaseIterable, Sendable { case gui, cli }
public enum LaunchMethod: String, Codable, CaseIterable, Sendable { case environment, environmentAndChromium }

public struct ProxyConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var `protocol`: ProxyProtocol
    public var host: String
    public var port: Int
    public var bypass: [String]

    public init(enabled: Bool = false, protocol: ProxyProtocol = .http, host: String = "127.0.0.1", port: Int = 7897, bypass: [String] = ["localhost", "127.0.0.1", "::1"]) {
        self.enabled = enabled; self.protocol = `protocol`; self.host = host; self.port = port; self.bypass = bypass
    }
    private enum CodingKeys: String, CodingKey { case enabled, `protocol`, host, port, bypass }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Existing installations opt in explicitly too; an old proxy address
        // is not evidence that the user enabled the new optional feature.
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        `protocol` = try values.decode(ProxyProtocol.self, forKey: .protocol)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        bypass = try values.decode([String].self, forKey: .bypass)
    }
    public var url: String {
        let hostname = host.contains(":") ? "[\(host)]" : host
        return "\(`protocol`.rawValue)://\(hostname):\(port)"
    }
    public func validate() throws {
        guard !host.isEmpty, host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !host.contains("/"), !host.contains("@"), !host.contains("["), !host.contains("]"),
              !host.contains("?"), !host.contains("#"), !host.contains("\0"), (1...65535).contains(port) else {
            throw LauncherError.invalidConfiguration("代理主机只能填写主机名或 IP，端口范围为 1–65535。")
        }
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { throw LauncherError.invalidConfiguration("主机字段不能包含端口；IPv6 请填写不带方括号的完整地址。") }
        }
        guard bypass.allSatisfy({ !$0.contains(where: { $0.isNewline || $0 == "\0" || $0 == "," || $0 == ";" }) }) else {
            throw LauncherError.invalidConfiguration("绕过地址不能包含换行、逗号或分号。")
        }
    }
    /// Replace inherited proxy settings rather than accidentally combining protocols.
    public func environment(inheriting original: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = original
        let proxyKeys: Set<String> = ["http_proxy", "https_proxy", "all_proxy", "no_proxy", "ftp_proxy", "rsync_proxy"]
        for key in original.keys where proxyKeys.contains(key.lowercased()) { env.removeValue(forKey: key) }
        guard enabled else { return env }
        // The scheme is intentional: SOCKS-aware clients receive SOCKS, never a fake HTTP endpoint.
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] { env[key] = url }
        env["NO_PROXY"] = bypass.joined(separator: ",")
        env["no_proxy"] = bypass.joined(separator: ",")
        return env
    }
    public var chromiumArguments: [String] {
        guard enabled else { return [] }
        var args = ["--proxy-server=\(url)"]
        if !bypass.isEmpty { args.append("--proxy-bypass-list=\(bypass.joined(separator: ";"))") }
        return args
    }
}

public struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: AppKind
    public var path: String
    public var arguments: [String]
    public var launchMethod: LaunchMethod
    public var bundleIdentifier: String?
    public var notes: String?
    public var hotKey: HotKey?

    public init(id: String = UUID().uuidString, name: String, kind: AppKind, path: String, arguments: [String] = [], launchMethod: LaunchMethod = .environment, bundleIdentifier: String? = nil, notes: String? = nil, hotKey: HotKey? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.path = path; self.arguments = arguments
        self.launchMethod = launchMethod; self.bundleIdentifier = bundleIdentifier; self.notes = notes
        self.hotKey = hotKey
    }
    private enum CodingKeys: String, CodingKey { case id, name, kind, path, arguments, launchMethod, bundleIdentifier, notes, hotKey }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(AppKind.self, forKey: .kind)
        path = try values.decode(String.self, forKey: .path)
        arguments = try values.decode([String].self, forKey: .arguments)
        launchMethod = try values.decodeIfPresent(LaunchMethod.self, forKey: .launchMethod) ?? .environment
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        hotKey = try values.decodeIfPresent(HotKey.self, forKey: .hotKey)
        let savedNotes = try values.decodeIfPresent(String.self, forKey: .notes)
        let legacyNotes: Set<String> = [
            "同时传入代理环境变量与 Chromium 参数；不保证所有网络组件使用代理。",
            "在 Terminal 中启动并注入代理环境变量；HTTP / SOCKS5 支持取决于当前 CLI 版本。运行中检测为尽力检查。",
            "仅传入环境变量。原生 App 可能不采用这些设置，代理效果未验证。"
        ]
        notes = savedNotes.flatMap { legacyNotes.contains($0) ? nil : $0 }
    }
    public func validate() throws {
        try hotKey?.validate()
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              path.hasPrefix("/"), !path.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw LauncherError.invalidConfiguration("App 名称不能为空，路径必须为绝对路径，参数不能包含空字符。")
        }
        if kind == .gui && !path.hasSuffix(".app") { throw LauncherError.invalidConfiguration("图形 App 的路径必须指向 .app。") }
        if arguments.contains(where: { $0 == "--no-proxy-server" || $0 == "--proxy-auto-detect" || $0.hasPrefix("--proxy-server") || $0.hasPrefix("--proxy-pac-url") || $0.hasPrefix("--proxy-bypass-list") }) {
            throw LauncherError.invalidConfiguration("请在代理配置中设置代理，不要在 App 参数中添加冲突的代理选项。")
        }
    }
    public func launchArguments(proxy: ProxyConfiguration) -> [String] {
        guard proxy.enabled else { return arguments }
        return arguments + (automaticLaunchMethod == .environmentAndChromium ? proxy.chromiumArguments : [])
    }
    /// Legacy launchMethod values remain Codable for compatibility, but the
    /// installed runtime determines whether Chromium switches are appropriate.
    public var automaticLaunchMethod: LaunchMethod {
        guard kind == .gui else { return .environment }
        let frameworks = URL(fileURLWithPath: path).appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let candidates = (try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil)) ?? []
        for framework in candidates where framework.pathExtension == "framework" {
            guard let bundle = Bundle(url: framework), bundle.infoDictionary?["CFBundlePackageType"] as? String == "FMWK" else { continue }
            if let identifier = bundle.bundleIdentifier,
               ["com.github.Electron.framework", "org.chromium.Chromium.framework", "com.google.Chrome.framework"].contains(identifier) {
                return .environmentAndChromium
            }
            // Chromium distributions can rename their framework and bundle ID.
            // Recognize their runtime layout, never the user-facing app name.
            guard let resources = bundle.resourceURL,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else { continue }
            let files = Set(names)
            let hasSnapshot = files.contains("snapshot_blob.bin") || files.contains(where: { $0.hasPrefix("v8_context_snapshot") && $0.hasSuffix(".bin") })
            if files.isSuperset(of: ["chrome_100_percent.pak", "resources.pak", "icudtl.dat"]), hasSnapshot {
                return .environmentAndChromium
            }
        }
        return .environment
    }
}

public struct LauncherConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var proxy: ProxyConfiguration
    public var profiles: [AppProfile]
    public init(version: Int = 1, proxy: ProxyConfiguration = ProxyConfiguration(), profiles: [AppProfile] = LauncherConfiguration.defaultProfiles()) {
        self.version = version; self.proxy = proxy; self.profiles = profiles
    }
    public func validate() throws {
        guard version == 1 else { throw LauncherError.invalidConfiguration("不支持的配置版本：\(version)") }
        try proxy.validate()
        guard Set(profiles.map(\.id)).count == profiles.count else { throw LauncherError.invalidConfiguration("App 配置 ID 不能重复。") }
        for profile in profiles { try profile.validate() }
        var shortcuts: [HotKey: String] = [:]
        for profile in profiles {
            guard let hotKey = profile.hotKey else { continue }
            if let name = shortcuts[hotKey] {
                throw LauncherError.invalidConfiguration("\(profile.name) 与 \(name) 使用了相同的快捷键 \(hotKey.displayString)，请选择不同的组合。")
            }
            shortcuts[hotKey] = profile.name
        }
    }
    public static var defaults: LauncherConfiguration { LauncherConfiguration() }
    public static func defaultProfiles() -> [AppProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
        let cliCandidates = pathCandidates + ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        let cli = cliCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/opt/homebrew/bin/codex"
        let codex = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?.path ?? "/Applications/Codex.app"
        let discoveredChat = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat")?.path
        let conventionalChat = Bundle(path: "/Applications/ChatGPT.app")?.bundleIdentifier == "com.openai.codex" ? "\(home)/Applications/ChatGPT.app" : "/Applications/ChatGPT.app"
        let chat = discoveredChat ?? conventionalChat
        return [
            AppProfile(id: "codex-app", name: "Codex", kind: .gui, path: codex, bundleIdentifier: "com.openai.codex"),
            AppProfile(id: "codex-cli", name: "Codex CLI", kind: .cli, path: cli),
            AppProfile(id: "chatgpt-app", name: "ChatGPT", kind: .gui, path: chat, bundleIdentifier: "com.openai.chat")
        ]
    }
}

public struct ProxyCheckResult: Codable, Equatable, Sendable {
    public var available: Bool
    public var checkedAt: Date
    public var message: String
    public var `protocol`: ProxyProtocol
    public var host: String
    public var port: Int
    public init(available: Bool, checkedAt: Date = Date(), message: String, proxy: ProxyConfiguration) {
        self.available = available; self.checkedAt = checkedAt; self.message = message
        self.protocol = proxy.protocol; self.host = proxy.host; self.port = proxy.port
    }
    public func matches(_ proxy: ProxyConfiguration) -> Bool { `protocol` == proxy.protocol && host == proxy.host && port == proxy.port }
}

public enum LaunchState: String, Codable, Sendable { case launched, activated, alreadyRunning, proxyUnavailable, failed, requested, exited }
public struct LaunchRecord: Codable, Equatable, Sendable {
    public var profileID: String
    public var state: LaunchState
    public var launchedAt: Date
    public var message: String
    public var pid: Int?
    public var trafficVerified: Bool
    public var requestID: String?
    public var proxy: ProxyConfiguration?
    public init(profileID: String, state: LaunchState, launchedAt: Date = Date(), message: String, pid: Int? = nil, trafficVerified: Bool = false, requestID: String? = nil, proxy: ProxyConfiguration? = nil) {
        self.profileID = profileID; self.state = state; self.launchedAt = launchedAt; self.message = message
        self.pid = pid; self.trafficVerified = trafficVerified; self.requestID = requestID; self.proxy = proxy
    }
}

public struct LauncherStatus: Codable, Sendable {
    public var version: Int
    public var updatedAt: Date
    public var launcherPID: Int?
    public var executablePath: String?
    public var startedAt: Date?
    public var proxy: ProxyCheckResult?
    public var launches: [LaunchRecord]
    public init(version: Int = 1, updatedAt: Date = Date(), launcherPID: Int? = nil, executablePath: String? = nil, startedAt: Date? = nil, proxy: ProxyCheckResult? = nil, launches: [LaunchRecord] = []) {
        self.version = version; self.updatedAt = updatedAt; self.launcherPID = launcherPID
        self.executablePath = executablePath; self.startedAt = startedAt; self.proxy = proxy; self.launches = launches
    }
}

public enum LauncherError: LocalizedError {
    case invalidConfiguration(String)
    case operation(String)
    public var errorDescription: String? {
        switch self { case .invalidConfiguration(let message), .operation(let message): return message }
    }
}
