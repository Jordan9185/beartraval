import AppCore
import CryptoKit
import Foundation
import UniformTypeIdentifiers

public struct InboxAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var order: Int
    public var typeIdentifier: String
    public var mimeType: String
    public var fileName: String
    public var byteCount: Int
    public var sha256: String

    public var isVideo: Bool { UTType(typeIdentifier)?.conforms(to: .movie) == true }
    public var isImage: Bool { UTType(typeIdentifier)?.conforms(to: .image) == true }
}

/// 分享擴充功能先寫入 App Group。ownerHint 是分享當下登入的帳號；nil 必須在 App 中確認歸屬。
public struct InboxCapture: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var ownerHint: UUID?
    public var syncedRemoteID: UUID?
    public var title: String?
    public var urls: [URL]
    public var texts: [String]
    public var assets: [InboxAsset]
    public var unavailableCount: Int

    public var canonicalURL: String? { urls.first.map(SourceURL.canonical) }
    public var rawText: String { texts.joined(separator: "\n\n") }
    public var fingerprint: String {
        let parts = [canonicalURL ?? "", title ?? "", rawText] + assets.map(\.sha256)
        return SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public init(id: UUID = UUID(), createdAt: Date = Date(), ownerHint: UUID? = nil,
                title: String? = nil, urls: [URL] = [], texts: [String] = [],
                assets: [InboxAsset] = [], unavailableCount: Int = 0) {
        self.id = id
        self.createdAt = createdAt
        self.ownerHint = ownerHint
        self.syncedRemoteID = nil
        self.title = title
        self.urls = urls
        self.texts = texts
        self.assets = assets
        self.unavailableCount = unavailableCount
    }
}

public enum InboxCaptureError: Error, Sendable {
    case appGroupUnavailable
    case emptyPayload
    case mediaTooLarge
    case mediaUnavailable
}

public struct InboxCaptureStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func shared() -> InboxCaptureStore? {
        AppGroup.containerURL.map { InboxCaptureStore(directory: $0.appending(path: "InboxCaptures", directoryHint: .isDirectory)) }
    }

    public func assetURL(captureID: UUID, asset: InboxAsset) -> URL {
        directory.appending(path: captureID.uuidString).appending(path: asset.fileName)
    }

    public func all() -> [InboxCapture] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return folders.filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap { folder in
            try? PayloadLogStore.decoder.decode(InboxCapture.self, from: Data(contentsOf: folder.appending(path: "capture.json")))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func claim(_ capture: InboxCapture, for userID: UUID) throws {
        var claimed = capture
        claimed.ownerHint = userID
        try PayloadLogStore.encoder.encode(claimed).write(
            to: directory.appending(path: capture.id.uuidString).appending(path: "capture.json"), options: .atomic)
    }

    public func markSynced(_ capture: InboxCapture, remoteID: UUID) throws {
        var updated = capture
        updated.syncedRemoteID = remoteID
        try PayloadLogStore.encoder.encode(updated).write(
            to: directory.appending(path: capture.id.uuidString).appending(path: "capture.json"), options: .atomic)
    }

    public func remove(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory.appending(path: id.uuidString))
    }

    public func removeAll(for userID: UUID) {
        for capture in all() where capture.ownerHint == userID { try? remove(capture.id) }
    }

    /// `NSItemProvider` 的暫存 URL 只在 callback 期間有效；每個檔案都在 callback 內複製。
    @MainActor
    public func capture(_ items: [NSExtensionItem], ownerHint: UUID?) async throws -> InboxCapture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let draft = directory.appending(path: ".\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: true)
        do {
            var capture = InboxCapture(ownerHint: ownerHint)
            var order = 0
            for item in items {
                if capture.title == nil { capture.title = item.attributedTitle?.string }
                if let text = item.attributedContentText?.string, !text.isEmpty { capture.texts.append(text) }
                for provider in item.attachments ?? [] {
                    let types = provider.registeredTypeIdentifiers
                    let mediaType = types.first { id in
                        guard let type = UTType(id) else { return false }
                        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
                    }
                    if let mediaType {
                        do {
                            if let asset = try await loadMedia(provider, typeID: mediaType, order: order, into: draft) {
                                capture.assets.append(asset)
                            } else { capture.unavailableCount += 1 }
                        } catch { capture.unavailableCount += 1 }
                        order += 1
                    }
                    if let urlType = types.first(where: { UTType($0)?.conforms(to: .url) == true }),
                       case .url(let url) = await loadValue(provider, typeID: urlType),
                       ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        if !capture.urls.contains(url) { capture.urls.append(url) }
                    }
                    if let textType = types.first(where: { UTType($0)?.conforms(to: .text) == true }),
                       case .text(let text) = await loadValue(provider, typeID: textType) {
                        if !text.isEmpty, !capture.texts.contains(text) { capture.texts.append(text) }
                    }
                }
            }
            for text in capture.texts {
                for url in ShareAnalysis.urls(in: text) where !capture.urls.contains(url) { capture.urls.append(url) }
            }
            guard !capture.urls.isEmpty || !capture.texts.isEmpty || !capture.assets.isEmpty ||
                  !(capture.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            else { throw InboxCaptureError.emptyPayload }
            if let existing = all().first(where: { old in
                old.ownerHint == capture.ownerHint &&
                (old.canonicalURL != nil && old.canonicalURL == capture.canonicalURL || old.fingerprint == capture.fingerprint)
            }) {
                try FileManager.default.removeItem(at: draft)
                return existing
            }
            try PayloadLogStore.encoder.encode(capture).write(to: draft.appending(path: "capture.json"), options: .atomic)
            try FileManager.default.moveItem(at: draft, to: directory.appending(path: capture.id.uuidString))
            return capture
        } catch {
            try? FileManager.default.removeItem(at: draft)
            throw error
        }
    }

    private enum CaptureValue: Sendable { case url(URL), text(String) }

    @MainActor
    private func loadValue(_ provider: NSItemProvider, typeID: String) async -> CaptureValue? {
        nonisolated(unsafe) let shared = provider
        return await withCheckedContinuation { continuation in
            let once = CaptureOnce<CaptureValue?>()
            once.install(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { once.resume(nil) }
            shared.loadItem(forTypeIdentifier: typeID, options: nil) { value, _ in
                if let url = value as? URL { once.resume(.url(url)) }
                else if let text = value as? String { once.resume(.text(text)) }
                else if let data = value as? Data {
                    if let url = PayloadInspector.decodeURL(data) { once.resume(.url(url)) }
                    else { once.resume(String(data: data, encoding: .utf8).map(CaptureValue.text)) }
                } else { once.resume(nil) }
            }
        }
    }

    @MainActor
    private func loadMedia(_ provider: NSItemProvider, typeID: String, order: Int, into draft: URL) async throws -> InboxAsset? {
        nonisolated(unsafe) let shared = provider
        let result: Result<InboxAsset?, InboxCaptureError> = await withCheckedContinuation { continuation in
            let once = CaptureOnce<Result<InboxAsset?, InboxCaptureError>>()
            once.install(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { once.resume(.success(nil)) }
            _ = shared.loadFileRepresentation(forTypeIdentifier: typeID) { temporary, error in
                guard let temporary else { once.resume(error == nil ? .success(nil) : .failure(.mediaUnavailable)); return }
                do {
                    let type = UTType(typeID)
                    let maxBytes = type?.conforms(to: .image) == true ? 30_000_000 : 150_000_000
                    let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= maxBytes else { throw InboxCaptureError.mediaTooLarge }
                    let ext = type?.preferredFilenameExtension ?? temporary.pathExtension
                    let name = "\(order)-\(UUID().uuidString).\(ext.isEmpty ? "bin" : ext)"
                    let target = draft.appending(path: name)
                    try FileManager.default.copyItem(at: temporary, to: target)
                    let checksum = try Self.sha256(file: target)
                    once.resume(.success(InboxAsset(id: UUID(), order: order, typeIdentifier: typeID,
                                                     mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                                                     fileName: name, byteCount: size, sha256: checksum)))
                } catch { once.resume(.failure((error as? InboxCaptureError) ?? .mediaUnavailable)) }
            }
        }
        return try result.get()
    }

    private static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class CaptureOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func install(_ continuation: CheckedContinuation<T, Never>) { lock.withLock { self.continuation = continuation } }
    func resume(_ value: T) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
