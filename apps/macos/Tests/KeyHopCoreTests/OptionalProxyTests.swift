import Darwin
import Foundation
import Testing
@testable import KeyHopCore

@Suite("Optional proxy and automatic launch configuration")
struct OptionalProxyTests {
    @Test func freshAndLegacyConfigurationsRequireExplicitOptIn() throws {
        #expect(!LauncherConfiguration.defaults.proxy.enabled)
        #expect(LauncherConfiguration.defaults.profiles.allSatisfy { $0.hotKey == nil && $0.notes == nil })
        let old = Data(#"{"version":1,"proxy":{"protocol":"http","host":"127.0.0.1","port":7897,"bypass":[]},"profiles":[]}"#.utf8)
        let config = try JSONDecoder().decode(LauncherConfiguration.self, from: old)
        #expect(!config.proxy.enabled)
        #expect(config.proxy.environment(inheriting: [:]).isEmpty)
    }

    @Test func explicitOptInSurvivesStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(rootURL: directory)
        let configuration = LauncherConfiguration(proxy: ProxyConfiguration(enabled: true, protocol: .socks5), profiles: [])
        try store.save(configuration)
        #expect(try store.load() == configuration)
        #expect(try store.load().proxy.enabled)
    }

    @Test func disabledProxyStripsInheritedSettingsAndProducesNoSwitches() {
        let proxy = ProxyConfiguration()
        let inherited = ["HTTP_PROXY": "old", "https_proxy": "old", "ALL_PROXY": "old", "no_proxy": "*", "Ftp_Proxy": "old", "RSYNC_PROXY": "old", "KEEP": "value"]
        #expect(proxy.environment(inheriting: inherited) == ["KEEP": "value"])
        #expect(proxy.chromiumArguments.isEmpty)
        let legacyCLI = AppProfile(name: "CLI", kind: .cli, path: "/usr/bin/true", arguments: ["custom"], launchMethod: .environmentAndChromium)
        #expect(throws: Never.self) { try legacyCLI.validate() }
        #expect(legacyCLI.launchArguments(proxy: proxy) == ["custom"])
        #expect(legacyCLI.launchArguments(proxy: ProxyConfiguration(enabled: true)) == ["custom"])
    }

    @Test func oldGeneratedNotesAreRemovedButCustomNotesSurvive() throws {
        let profile = AppProfile(name: "Test", kind: .cli, path: "/usr/bin/true", notes: "仅传入环境变量。原生 App 可能不采用这些设置，代理效果未验证。")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        #expect(try decoder.decode(AppProfile.self, from: encoder.encode(profile)).notes == nil)
        var custom = profile; custom.notes = "我的常用终端"
        #expect(try decoder.decode(AppProfile.self, from: encoder.encode(custom)).notes == custom.notes)
    }

    @Test func nativeAppNeverReceivesLegacyChromiumSwitches() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        let native = fixture.profile(launchMethod: .environmentAndChromium)
        #expect(native.automaticLaunchMethod == .environment)
        #expect(native.launchArguments(proxy: ProxyConfiguration(enabled: true)).isEmpty)
    }

    @Test func frameworkIdentityDeterminesArgumentsIndependentlyOfAppName() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.addFramework(identifier: "com.github.Electron.framework")
        let profile = fixture.profile(launchMethod: .environment)
        #expect(profile.automaticLaunchMethod == .environmentAndChromium)
        #expect(profile.launchArguments(proxy: ProxyConfiguration(enabled: true)).contains("--proxy-server=http://127.0.0.1:7897"))
        #expect(profile.launchArguments(proxy: ProxyConfiguration()).isEmpty)
    }

    @Test func renamedChromiumRuntimeIsDetectedButPartialResourcesAreNot() throws {
        let chromium = try AppFixture(), native = try AppFixture()
        defer { chromium.remove(); native.remove() }
        try chromium.addFramework(identifier: "example.custom.framework", resources: ["chrome_100_percent.pak", "resources.pak", "icudtl.dat", "v8_context_snapshot.arm64.bin"])
        try native.addFramework(identifier: "example.native.framework", resources: ["icudtl.dat", "resources.pak"])
        #expect(chromium.profile().automaticLaunchMethod == .environmentAndChromium)
        #expect(native.profile().automaticLaunchMethod == .environment)
    }

    @Test @MainActor func disabledProxyLaunchesGUIWithoutAnyProxyService() async throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.addFramework(identifier: "com.github.Electron.framework")
        let profile = fixture.profile()
        let launcher = AppLauncher(store: ConfigStore(rootURL: fixture.root.appendingPathComponent("state")), existingInstanceCheck: { _ in false })
        let result = await launcher.launch(configuration: LauncherConfiguration(proxy: ProxyConfiguration(port: 1), profiles: [profile]), profile: profile)
        defer { if let pid = result.pid { kill(pid_t(pid), SIGTERM) } }
        #expect(result.state == .launched)
        #expect(result.proxy == nil)
        #expect(!result.trafficVerified)
        #expect(launcher.lastProxyCheck == nil)
        #expect(!result.message.contains("代理"))
        // Process creation can precede shell startup on a busy/signed macOS
        // host. Await the fixture evidence rather than racing its first write.
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: fixture.arguments.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: fixture.arguments, encoding: .utf8) == "")
        let env = try String(contentsOf: fixture.environment, encoding: .utf8)
        #expect(!env.lowercased().contains("http_proxy="))
        #expect(!env.lowercased().contains("https_proxy="))
        #expect(!env.lowercased().contains("all_proxy="))
    }

    @Test func disabledProxyCLIHelperRunsWithoutAnyProxyService() throws {
        let fixture = try AppFixture(sleep: false)
        defer { fixture.remove() }
        let profile = AppProfile(id: "cli", name: "CLI", kind: .cli, path: fixture.executable.path, launchMethod: .environmentAndChromium)
        let store = ConfigStore(rootURL: fixture.root.appendingPathComponent("state"))
        let request = CLILaunchRequest(id: UUID().uuidString, configuration: LauncherConfiguration(proxy: ProxyConfiguration(port: 1), profiles: [profile]), profile: profile)
        try store.saveRequest(request)
        #expect(CLIHelper.run(requestID: request.id, store: store) == 0)
        let receipt: LaunchRecord = try store.read(store.receiptURL(request.id))
        #expect(receipt.state == .exited)
        #expect(receipt.proxy == nil)
        #expect(!receipt.trafficVerified)
        #expect(!receipt.message.contains("代理"))
        #expect(try String(contentsOf: fixture.arguments, encoding: .utf8) == "")
    }
}

private struct AppFixture {
    let root: URL
    let app: URL
    let executable: URL
    let environment: URL
    let arguments: URL

    init(sleep: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("keyhop-proxy-test-\(UUID().uuidString)")
        app = root.appendingPathComponent("Unrelated Name.app")
        executable = app.appendingPathComponent("Contents/MacOS/probe")
        environment = root.appendingPathComponent("environment.txt")
        arguments = root.appendingPathComponent("arguments.txt")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = ["CFBundleExecutable": "probe", "CFBundleIdentifier": "test.keyhop.\(UUID().uuidString)", "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let script = "#!/bin/sh\n/usr/bin/env > \(ShellCommand.quote(environment.path))\n: > \(ShellCommand.quote(arguments.path))\nfor argument do /usr/bin/printf '%s\\n' \"$argument\" >> \(ShellCommand.quote(arguments.path)); done\n" + (sleep ? "exec /bin/sleep 10\n" : "exit 0\n")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func profile(launchMethod: LaunchMethod = .environment) -> AppProfile {
        AppProfile(id: "gui", name: "Unrelated Name", kind: .gui, path: app.path, launchMethod: launchMethod)
    }
    func addFramework(identifier: String, resources: [String] = []) throws {
        let directory = app.appendingPathComponent("Contents/Frameworks/Unrelated.framework/Resources")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "FMWK"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
        for name in resources { try Data().write(to: directory.appendingPathComponent(name)) }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
