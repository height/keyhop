import Foundation

public struct CLILaunchRequest: Codable, Sendable {
    public var id: String
    public var createdAt: Date
    public var configuration: LauncherConfiguration
    public var profile: AppProfile
    public var launchPath: String?
    public init(id: String, createdAt: Date = Date(), configuration: LauncherConfiguration, profile: AppProfile, launchPath: String? = ProcessInfo.processInfo.environment["PATH"]) {
        self.id = id; self.createdAt = createdAt; self.configuration = configuration; self.profile = profile; self.launchPath = launchPath
    }
}

public struct ConfigStore: Sendable {
    public let rootURL: URL
    public var configURL: URL { rootURL.appendingPathComponent("config.json") }
    public var statusURL: URL { rootURL.appendingPathComponent("status.json") }
    public var requestsURL: URL { rootURL.appendingPathComponent("requests", isDirectory: true) }
    public var receiptsURL: URL { rootURL.appendingPathComponent("receipts", isDirectory: true) }
    public init(rootURL: URL? = nil) {
        if let rootURL { self.rootURL = rootURL }
        else if let override = ProcessInfo.processInfo.environment["KEYHOP_HOME"], override.hasPrefix("/") { self.rootURL = URL(fileURLWithPath: override, isDirectory: true) }
        else { self.rootURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KeyHop", isDirectory: true) }
    }
    public func load() throws -> LauncherConfiguration {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return LauncherConfiguration() }
        let config: LauncherConfiguration = try read(configURL)
        try config.validate()
        return config
    }
    public func save(_ configuration: LauncherConfiguration) throws {
        try configuration.validate()
        try write(configuration, to: configURL)
    }
    public func loadStatus() throws -> LauncherStatus? {
        guard FileManager.default.fileExists(atPath: statusURL.path) else { return nil }
        return try read(statusURL)
    }
    public func saveStatus(_ status: LauncherStatus) throws { try write(status, to: statusURL) }
    public func saveRequest(_ request: CLILaunchRequest) throws { try write(request, to: requestURL(request.id)) }
    public func loadRequest(_ id: String) throws -> CLILaunchRequest { try read(requestURL(id)) }
    public func saveReceipt(_ record: LaunchRecord, requestID: String) throws { try write(record, to: receiptURL(requestID)) }
    public func loadReceipts() throws -> [LaunchRecord] {
        guard FileManager.default.fileExists(atPath: receiptsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: receiptsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { try? read($0) as LaunchRecord }
    }
    public func requestURL(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw LauncherError.operation("无效的启动请求 ID。") }
        return requestsURL.appendingPathComponent("\(id).json")
    }
    public func receiptURL(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw LauncherError.operation("无效的启动请求 ID。") }
        return receiptsURL.appendingPathComponent("\(id).json")
    }
    public func write<T: Encodable>(_ value: T, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func read<T: Decodable>(_ url: URL) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }
}
