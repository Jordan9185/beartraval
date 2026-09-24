import AppCore
import Foundation

/// 把 Payload Inspector 紀錄寫進 App Group，讓 App 讀取與匯出。
public struct PayloadLogStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// App Group 未設定（例如簽章沒帶 entitlement）時回傳 nil。
    public static func shared() -> PayloadLogStore? {
        AppGroup.containerURL.map { PayloadLogStore(directory: $0.appending(path: "PayloadInspector", directoryHint: .isDirectory)) }
    }

    public func save(_ record: PayloadRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(record)
        try data.write(to: directory.appending(path: "\(record.id.uuidString).json"), options: .atomic)
    }

    /// 新到舊。
    public func all() throws -> [PayloadRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try files
            .map { try Self.decoder.decode(PayloadRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// 全部紀錄合成一個 JSON 陣列，寫到暫存檔供分享匯出。
    public func exportFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "payload-inspector-\(Int(Date().timeIntervalSince1970)).json")
        try Self.encoder.encode(all()).write(to: url, options: .atomic)
        return url
    }

    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
