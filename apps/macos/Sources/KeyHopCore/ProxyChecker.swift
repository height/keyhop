import Darwin
import Foundation

/// A successful TCP connection alone is not proxy evidence. Both probes ask the
/// selected protocol to establish a tunnel; they do not inspect any target App.
public struct ProxyChecker: Sendable {
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 4) { self.timeout = timeout }
    public func check(_ proxy: ProxyConfiguration) async -> ProxyCheckResult {
        await Task.detached(priority: .utility) { checkSynchronously(proxy) }.value
    }
    public func checkSynchronously(_ proxy: ProxyConfiguration) -> ProxyCheckResult {
        do {
            try proxy.validate()
            let connection = try ProbeSocket(host: proxy.host, port: proxy.port, timeout: timeout)
            switch proxy.protocol {
            case .http:
                try connection.send(Array("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nProxy-Connection: close\r\n\r\n".utf8))
                let headers = try connection.readHeaders()
                guard let first = String(bytes: headers, encoding: .utf8)?.components(separatedBy: "\r\n").first else { throw ProbeFailure("HTTP 代理响应无法解析。") }
                let fields = first.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(fields[0])), let code = Int(fields[1]) else {
                    throw ProbeFailure("端口已连接，但未返回 HTTP 代理响应；请检查协议。")
                }
                guard code == 200 else {
                    if code == 407 { throw ProbeFailure("HTTP 代理要求身份验证，第一版暂不支持。") }
                    throw ProbeFailure("HTTP CONNECT 失败（\(code)）；端口可达，但代理隧道不可用。")
                }
            case .socks5:
                try connection.send([0x05, 0x01, 0x00])
                let greeting = try connection.readExactly(2)
                guard greeting[0] == 0x05 else { throw ProbeFailure("端口已连接，但不是 SOCKS5 协议响应。") }
                guard greeting[1] == 0x00 else { throw ProbeFailure("SOCKS5 代理不接受无认证连接，第一版暂不支持认证。") }
                let target = Array("example.com".utf8)
                try connection.send([0x05, 0x01, 0x00, 0x03, UInt8(target.count)] + target + [0x01, 0xbb])
                let reply = try connection.readExactly(4)
                guard reply[0] == 0x05, reply[2] == 0x00 else { throw ProbeFailure("SOCKS5 隧道响应无效。") }
                guard reply[1] == 0x00 else { throw ProbeFailure("SOCKS5 隧道建立失败（错误 \(reply[1])）；端口可达但代理不可用。") }
                switch reply[3] {
                case 0x01: _ = try connection.readExactly(6)
                case 0x04: _ = try connection.readExactly(18)
                case 0x03:
                    let length = try connection.readExactly(1)[0]
                    _ = try connection.readExactly(Int(length) + 2)
                default: throw ProbeFailure("SOCKS5 返回未知地址类型。")
                }
            }
            return ProxyCheckResult(available: true, message: "\(proxy.protocol.rawValue.uppercased()) 代理隧道握手成功（example.com:443）；目标 App 流量仍未验证。", proxy: proxy)
        } catch {
            return ProxyCheckResult(available: false, message: error.localizedDescription, proxy: proxy)
        }
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class ProbeSocket {
    private var fd: Int32 = -1
    private let deadline: Date
    init(host: String, port: Int, timeout: TimeInterval) throws {
        deadline = Date().addingTimeInterval(max(0.1, timeout))
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
        var addresses: UnsafeMutablePointer<addrinfo>?
        let resolved = getaddrinfo(host, String(port), &hints, &addresses)
        guard resolved == 0, let first = addresses else { throw ProbeFailure("无法解析代理主机：\(host)。") }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let address = current {
            let candidate = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if candidate >= 0 {
                fd = candidate
                var enabled: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                let result = Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
                do {
                    if result != 0 {
                        guard errno == EINPROGRESS else { throw ProbeFailure("连接失败。") }
                        try wait(POLLOUT)
                        var connectionError: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &connectionError, &length) == 0, connectionError == 0 else { throw ProbeFailure("连接失败。") }
                    }
                    return
                } catch { close(fd); fd = -1 }
            }
            current = address.pointee.ai_next
        }
        throw ProbeFailure("无法连接代理 \(host):\(port)，或连接超时。请先启动代理软件。")
    }
    deinit { if fd >= 0 { close(fd) } }
    private func wait(_ eventMask: Int32) throws {
        let events = Int16(eventMask)
        let milliseconds = Int32(max(0, min(60_000, deadline.timeIntervalSinceNow * 1000)))
        guard milliseconds > 0 else { throw ProbeFailure("代理协议握手超时；请检查所选协议与端口。") }
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, milliseconds)
        guard result > 0 else { throw ProbeFailure("代理协议握手超时；请检查所选协议与端口。") }
        guard descriptor.revents & events != 0 else { throw ProbeFailure("代理在完成协议握手前关闭了连接。") }
    }
    func send(_ bytes: [UInt8]) throws {
        var written = 0
        while written < bytes.count {
            try wait(POLLOUT)
            let count = bytes.withUnsafeBytes { pointer in Darwin.send(fd, pointer.baseAddress!.advanced(by: written), bytes.count - written, 0) }
            guard count > 0 else { throw ProbeFailure("无法向代理发送协议握手。") }
            written += count
        }
    }
    func readExactly(_ length: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        var received = 0
        while received < length {
            try wait(POLLIN)
            let count = bytes.withUnsafeMutableBytes { pointer in recv(fd, pointer.baseAddress!.advanced(by: received), length - received, 0) }
            guard count > 0 else { throw ProbeFailure("代理返回了不完整的协议响应；请检查协议。") }
            received += count
        }
        return bytes
    }
    func readHeaders() throws -> [UInt8] {
        var bytes: [UInt8] = []
        while bytes.count < 8192 {
            bytes += try readExactly(1)
            if bytes.suffix(4).elementsEqual([13, 10, 13, 10]) { return bytes }
        }
        throw ProbeFailure("HTTP 代理响应头过长或格式无效。")
    }
}
