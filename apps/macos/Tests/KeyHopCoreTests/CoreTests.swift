import AppKit
import Darwin
import Foundation
import Testing
@testable import KeyHopCore

@Suite("Configuration and isolated persistence")
struct ConfigurationTests {
    @Test func protocolsNeverInventAMixedPort() throws {
        let socks = ProxyConfiguration(enabled: true, protocol: .socks5, host: "::1", port: 7897)
        let env = socks.environment(inheriting: ["HTTP_PROXY": "http://old:8888", "https_proxy": "bad", "KEEP": "value", "NO_PROXY": "*"])
        #expect(env["HTTP_PROXY"] == "socks5://[::1]:7897")
        #expect(env["https_proxy"] == env["HTTP_PROXY"])
        #expect(env["ALL_PROXY"] == env["HTTP_PROXY"])
        #expect(env["KEEP"] == "value")
        #expect(env["NO_PROXY"] == "localhost,127.0.0.1,::1")
        #expect(socks.chromiumArguments[0] == "--proxy-server=socks5://[::1]:7897")
    }

    @Test func invalidProxyInputsAreRejected() {
        for host in ["", "http://127.0.0.1", "user@localhost", "localhost/path", "local\nhost", "[::1]", "localhost:7897"] {
            #expect(throws: (any Error).self) { try ProxyConfiguration(enabled: true, host: host).validate() }
        }
        for port in [0, -1, 65536] { #expect(throws: (any Error).self) { try ProxyConfiguration(enabled: true, port: port).validate() } }
    }

    @Test func conflictingAppOptionsAreRejected() {
        let app = AppProfile(name: "Test", kind: .gui, path: "/Applications/Test.app", arguments: ["--no-proxy-server"])
        #expect(throws: (any Error).self) { try app.validate() }
        let relative = AppProfile(name: "Test", kind: .cli, path: "codex")
        #expect(throws: (any Error).self) { try relative.validate() }
    }

    @Test func saveLoadIsAtomicAndMalformedDataIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(rootURL: directory)
        let configuration = LauncherConfiguration(proxy: ProxyConfiguration(enabled: true, protocol: .socks5), profiles: [AppProfile(id: "test", name: "Test", kind: .cli, path: "/usr/bin/true")])
        try store.save(configuration)
        #expect(try store.load() == configuration)
        let mode = try FileManager.default.attributesOfItem(atPath: store.configURL.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        try Data("{invalid".utf8).write(to: store.configURL)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try String(contentsOf: store.configURL, encoding: .utf8) == "{invalid")
    }

    @Test func statusHasStableISO8601AndNoFalseTrafficEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(rootURL: directory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let record = LaunchRecord(profileID: "test", state: .requested, launchedAt: date, message: "Waiting")
        try store.saveStatus(LauncherStatus(updatedAt: date, launcherPID: 123, launches: [record]))
        let data = try String(contentsOf: store.statusURL, encoding: .utf8)
        #expect(data.contains("2023-11-14T22:13:20Z"))
        #expect(try store.loadStatus()?.launches[0].trafficVerified == false)
        #expect(throws: (any Error).self) { try store.requestURL("../../config") }
    }

    @Test func shellWordsRoundTripWithoutEvaluation() throws {
        let values = ["plain", "a b", "single'quote", "$HOME", "`uname`", "$(uname)", "line\nbreak", "中文", ""]
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\000' " + values.map(ShellCommand.quote).joined(separator: " ")]
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(bytes == Data((values.joined(separator: "\0") + "\0").utf8))
        let script = ShellCommand.terminalScript(helper: "/a b/it's app", root: "/tmp/$(uname)", requestID: "literal")
        #expect(script.contains("export KEYHOP_HOME='/tmp/$(uname)'"))
    }
}

@Suite("Selected proxy protocol handshake")
struct ProxyTests {
    @Test func httpConnectIsRequired() throws {
        let server = try SocketFixture { fd in
            let request = SocketFixture.readHeaders(fd)
            if request.hasPrefix("CONNECT example.com:443 HTTP/1.1") { SocketFixture.send(fd, Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8)) }
        }
        let result = ProxyChecker(timeout: 1).checkSynchronously(ProxyConfiguration(enabled: true, port: server.port))
        #expect(result.available)
        #expect(result.protocol == .http)
        #expect(result.message.contains("流量仍未验证"))
    }

    @Test func socksRequiresGreetingAndConnectReply() throws {
        let server = try SocketFixture { fd in
            guard SocketFixture.read(fd, 3) == [5, 1, 0] else { return }
            SocketFixture.send(fd, [5, 0])
            let header = SocketFixture.read(fd, 5)
            guard header.count == 5, header[3] == 3 else { return }
            _ = SocketFixture.read(fd, Int(header[4]) + 2)
            SocketFixture.send(fd, [5, 0, 0, 1, 127, 0, 0, 1, 0, 80])
        }
        let result = ProxyChecker(timeout: 1).checkSynchronously(ProxyConfiguration(enabled: true, protocol: .socks5, port: server.port))
        #expect(result.available)
        #expect(result.protocol == .socks5)
    }

    @Test func socksSelectionRejectsHTTPResponseOnSamePort() throws {
        let server = try SocketFixture { fd in
            _ = SocketFixture.read(fd, 3)
            SocketFixture.send(fd, Array("HTTP/1.1 200 OK\r\n\r\n".utf8))
        }
        #expect(!ProxyChecker(timeout: 0.3).checkSynchronously(ProxyConfiguration(enabled: true, protocol: .socks5, port: server.port)).available)
    }

    @Test func httpSelectionRejectsSOCKSResponseOnSamePort() throws {
        let server = try SocketFixture { fd in
            _ = SocketFixture.read(fd, 3)
            SocketFixture.send(fd, [5, 0])
        }
        #expect(!ProxyChecker(timeout: 0.3).checkSynchronously(ProxyConfiguration(enabled: true, protocol: .http, port: server.port)).available)
    }

    @Test(arguments: ["HTTP/1.1 405 Method Not Allowed", "HTTP/1.1 407 Proxy Authentication Required", "HTTP/1.1 502 Bad Gateway"])
    func reachableHTTPFailureIsNotProxySuccess(status: String) throws {
        let server = try SocketFixture { fd in
            _ = SocketFixture.readHeaders(fd)
            SocketFixture.send(fd, Array((status + "\r\n\r\n").utf8))
        }
        #expect(!ProxyChecker(timeout: 1).checkSynchronously(ProxyConfiguration(enabled: true, port: server.port)).available)
    }

    @Test func refusedConnectionIsUnavailable() throws {
        let port = try SocketFixture.unusedPort()
        #expect(!ProxyChecker(timeout: 0.2).checkSynchronously(ProxyConfiguration(enabled: true, port: port)).available)
    }

    @Test func socksAuthenticationIsNotSupportedSilently() throws {
        let server = try SocketFixture { fd in
            _ = SocketFixture.read(fd, 3); SocketFixture.send(fd, [5, 2])
        }
        let result = ProxyChecker(timeout: 1).checkSynchronously(ProxyConfiguration(enabled: true, protocol: .socks5, port: server.port))
        #expect(!result.available)
        #expect(result.message.contains("认证"))
    }

    @Test func socksGreetingAloneDoesNotProveAnAvailableTunnel() throws {
        let server = try SocketFixture { fd in
            _ = SocketFixture.read(fd, 3); SocketFixture.send(fd, [5, 0])
            let request = SocketFixture.read(fd, 5)
            guard request.count == 5 else { return }
            _ = SocketFixture.read(fd, Int(request[4]) + 2)
            SocketFixture.send(fd, [5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
        }
        let result = ProxyChecker(timeout: 1).checkSynchronously(ProxyConfiguration(enabled: true, protocol: .socks5, port: server.port))
        #expect(!result.available)
        #expect(result.message.contains("隧道建立失败"))
    }
}

@Suite("Launch guards")
@MainActor struct LaunchTests {
    @Test func runningApplicationIsNeverLaunchedOrTerminated() async {
        let profile = AppProfile(id: "test", name: "Test", kind: .gui, path: "/missing/Test.app")
        let launcher = AppLauncher(store: ConfigStore(), existingInstanceCheck: { _ in true })
        let result = await launcher.launch(configuration: LauncherConfiguration(profiles: [profile]), profile: profile)
        #expect(result.state == .alreadyRunning)
        #expect(result.pid == nil)
        #expect(!result.trafficVerified)
        #expect(launcher.lastProxyCheck == nil)
    }

    @Test func unknownProcessStateFailsClosed() async {
        let profile = AppProfile(name: "Test", kind: .cli, path: "/usr/bin/true")
        let launcher = AppLauncher(store: ConfigStore(), existingInstanceCheck: { _ in throw LauncherError.operation("Cannot inspect processes") })
        let result = await launcher.launch(configuration: LauncherConfiguration(profiles: [profile]), profile: profile)
        #expect(result.state == .failed)
        #expect(result.pid == nil)
    }

    @Test func unavailableProxyDoesNotStartExecutable() async throws {
        let profile = AppProfile(name: "Test", kind: .cli, path: "/usr/bin/true")
        let proxy = ProxyConfiguration(enabled: true, port: try SocketFixture.unusedPort())
        let launcher = AppLauncher(store: ConfigStore(), checker: ProxyChecker(timeout: 0.2), existingInstanceCheck: { _ in false })
        let result = await launcher.launch(configuration: LauncherConfiguration(proxy: proxy, profiles: [profile]), profile: profile)
        #expect(result.state == .proxyUnavailable)
        #expect(result.pid == nil)
        #expect(launcher.lastProxyCheck?.available == false)
    }
}

private final class SocketFixture: @unchecked Sendable {
    let fd: Int32
    let port: Int
    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        let pair = try Self.bind(); fd = pair.0; port = pair.1
        guard listen(fd, 1) == 0 else { close(fd); throw FixtureError() }
        let listener = fd
        DispatchQueue.global().async {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            handler(client)
        }
    }
    deinit { close(fd) }
    static func unusedPort() throws -> Int { let pair = try bind(); close(pair.0); return pair.1 }
    private static func bind() throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError() }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { close(fd); throw FixtureError() }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { pointer in _ = pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }
    static func read(_ fd: Int32, _ length: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: length); var total = 0
        while total < length {
            let count = result.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: total), length - total, 0) }
            guard count > 0 else { return Array(result.prefix(total)) }; total += count
        }
        return result
    }
    static func readHeaders(_ fd: Int32) -> String {
        var data: [UInt8] = []
        while data.count < 8192 {
            let byte = read(fd, 1); if byte.isEmpty { break }; data += byte
            if data.suffix(4).elementsEqual([13, 10, 13, 10]) { break }
        }
        return String(decoding: data, as: UTF8.self)
    }
    static func send(_ fd: Int32, _ bytes: [UInt8]) { _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, bytes.count, 0) } }
    private struct FixtureError: Error {}
}
