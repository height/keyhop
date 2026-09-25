import Foundation
import Testing
@testable import KeyHopCore

@Suite("Direct app activation")
@MainActor struct AppSummonTests {
    @Test func runningGUIIsActivatedWithoutCheckingProxyOrLaunching() async {
        let profile = AppProfile(id: "test", name: "Test", kind: .gui, path: "/missing/Test.app")
        var activationCount = 0
        var launchChecks = 0
        let launcher = AppLauncher(store: ConfigStore(), existingInstanceCheck: { _ in
            launchChecks += 1
            return false
        }, existingApplicationActivator: { requested in
            #expect(requested == profile)
            activationCount += 1
            return 1234
        })
        // An unavailable or invalid proxy must not prevent focusing an app.
        let configuration = LauncherConfiguration(proxy: ProxyConfiguration(enabled: true, port: 0), profiles: [profile])
        let result = await launcher.summon(configuration: configuration, profile: profile)
        #expect(result.state == .activated)
        #expect(result.pid == 1234)
        #expect(result.proxy == nil)
        #expect(!result.trafficVerified)
        #expect(result.message.contains("代理配置保持不变"))
        #expect(launcher.lastProxyCheck == nil)
        #expect(activationCount == 1)
        #expect(launchChecks == 0)
    }

    @Test func activationFailureDoesNotStartASecondInstance() async {
        let profile = AppProfile(name: "Test", kind: .gui, path: "/missing/Test.app")
        var launchChecks = 0
        let launcher = AppLauncher(store: ConfigStore(), existingInstanceCheck: { _ in
            launchChecks += 1
            return false
        }, existingApplicationActivator: { _ in
            throw LauncherError.operation("Activation refused")
        })
        let result = await launcher.summon(configuration: LauncherConfiguration(profiles: [profile]), profile: profile)
        #expect(result.state == .failed)
        #expect(result.message == "Activation refused")
        #expect(result.pid == nil)
        #expect(result.proxy == nil)
        #expect(!result.trafficVerified)
        #expect(launchChecks == 0)
    }

    @Test func absentGUIUsesNormalLaunchValidation() async {
        let profile = AppProfile(name: "Test", kind: .gui, path: "/missing/Test.app")
        var launchChecks = 0
        let launcher = AppLauncher(store: ConfigStore(), existingInstanceCheck: { _ in
            launchChecks += 1
            return false
        }, existingApplicationActivator: { _ in nil })
        let result = await launcher.summon(configuration: LauncherConfiguration(profiles: [profile]), profile: profile)
        #expect(result.state == .failed)
        #expect(result.message.contains("找不到有效的 App"))
        #expect(launchChecks == 1)
        #expect(!result.trafficVerified)
    }

    @Test func appOpeningDuringLaunchIsActivated() async {
        let profile = AppProfile(name: "Test", kind: .gui, path: "/missing/Test.app")
        var activationChecks = 0
        let launcher = AppLauncher(store: ConfigStore(), existingInstanceCheck: { _ in true }, existingApplicationActivator: { _ in
            activationChecks += 1
            return activationChecks == 1 ? nil : 4321
        })
        let result = await launcher.summon(configuration: LauncherConfiguration(profiles: [profile]), profile: profile)
        #expect(result.state == .activated)
        #expect(result.pid == 4321)
        #expect(activationChecks == 2)
        #expect(result.proxy == nil)
        #expect(!result.trafficVerified)
    }

    @Test func runningCLIDoesNotClaimItFocusedAnUnknownTerminalWindow() async {
        let profile = AppProfile(name: "Test CLI", kind: .cli, path: "/usr/bin/true")
        var activationChecks = 0
        let launcher = AppLauncher(store: ConfigStore(), existingInstanceCheck: { _ in true }, existingApplicationActivator: { _ in
            activationChecks += 1
            return 1234
        })
        let result = await launcher.summon(configuration: LauncherConfiguration(profiles: [profile]), profile: profile)
        #expect(result.state == .alreadyRunning)
        #expect(result.message.contains("请切换到现有终端"))
        #expect(result.pid == nil)
        #expect(result.proxy == nil)
        #expect(!result.trafficVerified)
        #expect(activationChecks == 0)
        #expect(launcher.lastProxyCheck == nil)
    }

    @Test(arguments: [true, false])
    func newGUIForegroundPreservesLaunchEvidence(foregroundSucceeds: Bool) async {
        let profile = AppProfile(id: "test", name: "Test", kind: .gui, path: "/missing/Test.app")
        let proxy = ProxyConfiguration(enabled: true, protocol: .socks5)
        let launched = LaunchRecord(profileID: profile.id, state: .launched, message: "已按配置启动；流量未验证。", pid: 4321, proxy: proxy)
        var activatedPIDs: [Int] = []
        let launcher = AppLauncher(store: ConfigStore(), existingApplicationActivator: { _ in
            Issue.record("A new process must not be located by profile")
            return 9876
        }, launchedApplicationActivator: { pid in
            activatedPIDs.append(pid)
            return foregroundSucceeds
        })
        let result = await launcher.foregroundNewGUI(launched, profile: profile)
        #expect(activatedPIDs == [4321])
        #expect(result.state == .launched)
        #expect(result.pid == launched.pid)
        #expect(result.proxy == proxy)
        #expect(result.launchedAt == launched.launchedAt)
        #expect(!result.trafficVerified)
        #expect(result.message.hasPrefix(launched.message))
        #expect(result.message.contains(foregroundSucceeds ? "App 已切换到前台" : "未确认切换到前台"))
    }

    @Test func failedOrPendingLaunchNeverAttemptsForeground() async {
        let profile = AppProfile(id: "test", name: "Test", kind: .gui, path: "/missing/Test.app")
        var attempted = false
        let launcher = AppLauncher(store: ConfigStore(), launchedApplicationActivator: { _ in
            attempted = true
            return true
        })
        for state in [LaunchState.failed, .alreadyRunning, .proxyUnavailable, .requested, .activated, .exited] {
            let record = LaunchRecord(profileID: profile.id, state: state, message: "Unchanged", pid: 4321)
            #expect(await launcher.foregroundNewGUI(record, profile: profile) == record)
        }
        let missingPID = LaunchRecord(profileID: profile.id, state: .launched, message: "Unchanged")
        #expect(await launcher.foregroundNewGUI(missingPID, profile: profile) == missingPID)
        var cli = profile
        cli.kind = .cli
        let cliRecord = LaunchRecord(profileID: profile.id, state: .launched, message: "Unchanged", pid: 4321)
        #expect(await launcher.foregroundNewGUI(cliRecord, profile: cli) == cliRecord)
        #expect(!attempted)
    }
}
