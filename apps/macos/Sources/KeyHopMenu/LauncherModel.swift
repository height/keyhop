import AppKit
import Foundation
import KeyHopCore
import SwiftUI

@MainActor
final class LauncherModel: ObservableObject {
    let store: ConfigStore
    @Published private(set) var configuration: LauncherConfiguration
    @Published private(set) var status: LauncherStatus
    @Published private(set) var isBusy = false
    @Published private(set) var isCheckingProxy = false
    @Published private(set) var hotKeyErrors: [String: String] = [:]
    @Published private(set) var configurationUsable = true
    @Published var errorMessage: String?
    @Published private(set) var notice: String?
    var onChange: (() -> Void)?
    var registerHotKeys: (([AppProfile]) -> [String: String])?
    var onShortcutRecordingChanged: ((Bool) -> [String: String])?
    private let launcher: AppLauncher
    private var active = false
    private var proxyCheckTask: Task<Void, Never>?
    private var proxyCheckID: UUID?

    init(store: ConfigStore) {
        self.store = store
        self.launcher = AppLauncher(store: store)
        do {
            configuration = try store.load()
        } catch {
            configuration = .defaults
            configurationUsable = false
            errorMessage = "配置文件无法读取：\(error.localizedDescription)。原文件已保留，请修正后重新载入。"
        }
        do { status = try store.loadStatus() ?? LauncherStatus() }
        catch { status = LauncherStatus() }
        // Old reachability is historical; probe again in this process.
        status.proxy = nil
    }

    var endpointDescription: String {
        let p = configuration.proxy
        let host = p.host.contains(":") ? "[\(p.host)]" : p.host
        return "\(p.protocol.rawValue.uppercased()) · \(host):\(p.port)"
    }

    var proxyIsFresh: Bool {
        guard configuration.proxy.enabled, let p = status.proxy else { return false }
        return Date().timeIntervalSince(p.checkedAt) < 60 && p.host == configuration.proxy.host
            && p.port == configuration.proxy.port && p.protocol == configuration.proxy.protocol
    }

    var proxyHeadline: String {
        if !configuration.proxy.enabled { return "代理未开启" }
        if isCheckingProxy { return "正在检查代理…" }
        guard let p = status.proxy else { return "代理服务：尚未检查" }
        guard proxyIsFresh else { return "代理服务：检查结果已过期" }
        return p.available ? "代理服务可用 · 所选协议探测通过" : "代理服务不可用"
    }

    var proxySummary: String {
        if !configuration.proxy.enabled { return "代理未开启" }
        if isCheckingProxy { return "检查中…" }
        guard status.proxy != nil else { return "尚未检查" }
        guard proxyIsFresh else { return "待检查" }
        return status.proxy?.available == true ? "代理可用" : "代理不可用"
    }

    var proxyColor: Color {
        guard proxyIsFresh, let p = status.proxy else { return .secondary }
        return p.available ? .green : .orange
    }

    func start() {
        active = true
        status.startedAt = Date()
        if configurationUsable {
            do { try store.save(configuration) }
            catch { report(error) }
            hotKeyErrors = registerHotKeys?(configuration.profiles) ?? [:]
        }
        persistStatus()
        scheduleProxyCheck()
    }

    func stop() {
        active = false
        resetProxyCheck()
        status.launcherPID = nil
        status.executablePath = nil
        status.updatedAt = Date()
        try? store.saveStatus(status)
    }

    func record(for profile: AppProfile) -> LaunchRecord? {
        status.launches.first(where: { $0.profileID == profile.id })
    }

    func checkIfStale() {
        if configuration.proxy.enabled && !proxyIsFresh && !isCheckingProxy { scheduleProxyCheck() }
    }

    func checkProxy() async {
        guard active, configuration.proxy.enabled, !isCheckingProxy, configurationUsable else { return }
        let checkID = UUID()
        proxyCheckID = checkID
        isCheckingProxy = true
        onChange?()
        let proxy = configuration.proxy
        let result = await ProxyChecker().check(proxy)
        guard active, proxyCheckID == checkID else { return }
        if configuration.proxy == proxy,
           status.proxy == nil || result.checkedAt >= status.proxy!.checkedAt { status.proxy = result }
        isCheckingProxy = false
        proxyCheckID = nil
        persistStatus()
    }

    private func resetProxyCheck() {
        proxyCheckTask?.cancel()
        proxyCheckTask = nil
        proxyCheckID = nil
        isCheckingProxy = false
        status.proxy = nil
    }

    private func scheduleProxyCheck() {
        guard active, configuration.proxy.enabled, configurationUsable else { return }
        proxyCheckTask = Task { await checkProxy() }
    }

    func setProxyEnabled(_ enabled: Bool) {
        guard configurationUsable, !isBusy, enabled != configuration.proxy.enabled else { return }
        do {
            var next = configuration
            next.proxy.enabled = enabled
            try store.save(next)
            configuration = next
            resetProxyCheck()
            errorMessage = nil
            notice = "设置已保存，将用于之后新启动的应用。"
            persistStatus()
            scheduleProxyCheck()
        } catch { report(error) }
    }

    @discardableResult
    func launch(_ profile: AppProfile, activateExisting: Bool = true) async -> LaunchRecord? {
        guard !isBusy, configurationUsable else { return nil }
        if let pending = record(for: profile), pending.state == .requested,
           Date().timeIntervalSince(pending.launchedAt) < 30 {
            notice = "正在等待 Terminal 执行上一次请求，请先查看终端窗口。"
            return pending
        }
        isBusy = true
        errorMessage = nil
        notice = nil
        onChange?()
        let record = activateExisting
            ? await launcher.summon(configuration: configuration, profile: profile)
            : await launcher.launch(configuration: configuration, profile: profile)
        guard active else { return record }
        if configuration.proxy.enabled, let probe = launcher.lastProxyCheck,
           probe.matches(configuration.proxy) { status.proxy = probe }
        merge(record)
        isBusy = false
        notice = record.message
        persistStatus()
        return record
    }

    func refreshReceipts() {
        guard active else { return }
        do {
            for receipt in try store.loadReceipts() {
                guard configuration.profiles.contains(where: { $0.id == receipt.profileID }) else { continue }
                merge(receipt)
            }
            // A launch record is historical. When its recorded PID exits, make that explicit.
            for index in status.launches.indices {
                let record = status.launches[index]
                if record.state == .requested && Date().timeIntervalSince(record.launchedAt) > 300 {
                    status.launches[index].state = .failed
                    status.launches[index].message = "Terminal 未在五分钟内确认执行，请重新启动。没有把请求标记为启动成功。"
                }
                if [.launched, .activated].contains(record.state), let pid = record.pid, kill(pid_t(pid), 0) != 0, errno == ESRCH {
                    status.launches[index].state = .exited
                    status.launches[index].message = record.proxy == nil ? "进程已退出。" : "该次启动的进程已结束；App 流量仍未验证。"
                }
            }
            persistStatus()
        } catch { report(error) }
    }

    private func merge(_ record: LaunchRecord) {
        if let index = status.launches.firstIndex(where: { $0.profileID == record.profileID }) {
            guard LaunchHistory.shouldReplace(status.launches[index], with: record) else { return }
            status.launches[index] = record
        } else { status.launches.append(record) }
    }

    @discardableResult
    func saveProxy(address: String, protocol proxyProtocol: ProxyProtocol, bypass: String) -> Bool {
        do {
            let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.contains("://"),
                  let url = URLComponents(string: "http://" + input),
                  let host = url.host, !host.isEmpty, let port = url.port,
                  url.user == nil, url.password == nil, url.path.isEmpty,
                  url.query == nil, url.fragment == nil else {
                throw UIError.invalidAddress
            }
            var next = configuration
            next.proxy = ProxyConfiguration(protocol: proxyProtocol,
                                             host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                                             port: port,
                                             bypass: bypass.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            next.proxy.enabled = configuration.proxy.enabled
            try store.save(next)
            configuration = next
            resetProxyCheck()
            errorMessage = nil
            notice = "代理配置已保存。已运行的 App 需要自行退出后重新启动，才会使用新配置。"
            persistStatus()
            scheduleProxyCheck()
            return true
        } catch { report(error); return false }
    }

    @discardableResult
    func saveProfile(_ profile: AppProfile) -> Bool {
        do {
            var next = configuration
            if let index = next.profiles.firstIndex(where: { $0.id == profile.id }) {
                next.profiles[index] = profile
            } else { next.profiles.append(profile) }
            try next.validate()
            let registrationErrors = registerHotKeys?(next.profiles) ?? [:]
            if profile.hotKey != nil, let message = registrationErrors[profile.id] {
                hotKeyErrors = registerHotKeys?(configuration.profiles) ?? [:]
                throw LauncherError.invalidConfiguration(message)
            }
            do { try store.save(next) }
            catch {
                hotKeyErrors = registerHotKeys?(configuration.profiles) ?? [:]
                throw error
            }
            configuration = next
            hotKeyErrors = registrationErrors
            errorMessage = nil
            notice = "应用配置已保存。"
            persistStatus()
            return true
        } catch { report(error); return false }
    }

    func removeProfile(_ id: String) {
        do {
            var next = configuration
            next.profiles.removeAll { $0.id == id }
            try store.save(next)
            configuration = next
            hotKeyErrors = registerHotKeys?(configuration.profiles) ?? [:]
            status.launches.removeAll { $0.profileID == id }
            persistStatus()
        } catch { report(error) }
    }

    func reloadConfiguration() {
        do {
            configuration = try store.load()
            configurationUsable = true
            hotKeyErrors = registerHotKeys?(configuration.profiles) ?? [:]
            errorMessage = nil
            resetProxyCheck()
            persistStatus()
            scheduleProxyCheck()
        } catch { report(error) }
    }

    func revealConfiguration() { NSWorkspace.shared.activateFileViewerSelecting([store.configURL]) }

    func setShortcutRecording(_ recording: Bool) {
        hotKeyErrors = onShortcutRecordingChanged?(recording) ?? hotKeyErrors
        onChange?()
    }

    private func persistStatus() {
        guard active else { return }
        status.launcherPID = Int(getpid())
        status.executablePath = Bundle.main.executableURL?.resolvingSymlinksInPath().path
        status.updatedAt = Date()
        do { try store.saveStatus(status) }
        catch { errorMessage = "运行状态无法保存：\(error.localizedDescription)" }
        onChange?()
    }

    private func report(_ error: Error) { errorMessage = error.localizedDescription; onChange?() }
}

private enum UIError: LocalizedError {
    case invalidAddress
    var errorDescription: String? { "请输入主机:端口，例如 127.0.0.1:7897 或 [::1]:7897。协议请在上方单独选择。" }
}
