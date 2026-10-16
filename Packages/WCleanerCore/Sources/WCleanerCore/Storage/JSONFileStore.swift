import Foundation

/// Location of WCleaner's non-secret local data (`~/Library/Application Support/WCleaner`).
public struct AppDataDirectory: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func standard(fileManager: FileManager = .default) -> AppDataDirectory {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AppDataDirectory(url: base.appendingPathComponent("WCleaner", isDirectory: true))
    }

    /// Creates the directory with owner-only permissions if needed.
    public func ensureExists() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    public func file(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: false)
    }
}

/// Atomic JSON persistence for a single Codable value. Never use it for secrets.
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public let fileURL: URL
    private let directory: AppDataDirectory

    public init(directory: AppDataDirectory, fileName: String) {
        self.directory = directory
        self.fileURL = directory.file(fileName)
    }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try Self.decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try directory.ensureExists()
        let data = try Self.encoder.encode(value)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    static var encoder: JSONEncoder { WCJSON.encoder(pretty: true) }
    static var decoder: JSONDecoder { WCJSON.decoder() }
}

/// JSON coding shared by all local stores: ISO 8601 dates with fractional seconds so values round-trip exactly.
public enum WCJSON {
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let legacyDateStyle = Date.ISO8601FormatStyle()

    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateStyle.format(date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? dateStyle.parse(text) { return date }
            if let date = try? legacyDateStyle.parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(text)")
        }
        return decoder
    }
}
