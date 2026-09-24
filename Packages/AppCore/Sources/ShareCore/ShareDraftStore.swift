import AppCore
import Foundation

/// 未登入或沒網路時的分享草稿，存在 App Group，開啟 App 後繼續（§5.3）。
public struct ShareDraft: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var content: ShareContent

    public init(id: UUID = UUID(), createdAt: Date = Date(), content: ShareContent) {
        self.id = id
        self.createdAt = createdAt
        self.content = content
    }
}

public struct ShareDraftStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func shared() -> ShareDraftStore? {
        AppGroup.containerURL.map { ShareDraftStore(directory: $0.appending(path: "ShareDrafts", directoryHint: .isDirectory)) }
    }

    public func save(_ draft: ShareDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PayloadLogStore.encoder.encode(draft).write(to: directory.appending(path: "\(draft.id.uuidString).json"), options: .atomic)
    }

    /// 舊到新。
    public func all() -> [ShareDraft] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? PayloadLogStore.decoder.decode(ShareDraft.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(id.uuidString).json"))
    }
}
