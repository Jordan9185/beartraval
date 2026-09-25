import AppCore
import Foundation
import UniformTypeIdentifiers

/// 逐一載入分享進來的每個 `NSItemProvider` 型別並記錄結果。
public enum PayloadInspector {
    public static let previewLimit = 500
    public static let loadTimeout: TimeInterval = 10

    /// 在 main actor 上執行：`NSExtensionItem`／`NSItemProvider` 不是 Sendable，由 Extension 的 UI 直接呼叫。
    @MainActor
    public static func inspect(_ extensionItems: [NSExtensionItem], sourceLabel: String? = nil,
                               timeout: TimeInterval = loadTimeout) async -> PayloadRecord {
        let start = Date()
        var items: [PayloadRecord.Item] = []
        for extensionItem in extensionItems {
            var attachments: [PayloadRecord.Attachment] = []
            for provider in extensionItem.attachments ?? [] {
                // 同一個附件的各種型別同時載入：總等待時間是最慢的那個，而不是全部加總（審查）。
                let types = provider.registeredTypeIdentifiers
                nonisolated(unsafe) let shared = provider
                var ordered = [PayloadRecord.Load?](repeating: nil, count: types.count)
                await withTaskGroup(of: (Int, PayloadRecord.Load).self) { group in
                    for (index, type) in types.enumerated() {
                        group.addTask { @MainActor in (index, await load(shared, type: type, timeout: timeout)) }
                    }
                    for await (index, result) in group { ordered[index] = result }
                }
                let loads = ordered.compactMap { $0 }
                attachments.append(.init(
                    registeredTypeIdentifiers: provider.registeredTypeIdentifiers,
                    suggestedName: provider.suggestedName,
                    loads: loads
                ))
            }
            items.append(.init(
                attributedTitle: extensionItem.attributedTitle?.string,
                attributedContentText: extensionItem.attributedContentText?.string,
                userInfoKeys: (extensionItem.userInfo ?? [:]).keys.map { "\($0)" }.sorted(),
                attachments: attachments
            ))
        }
        return PayloadRecord(
            id: UUID(),
            capturedAt: start,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            sourceLabel: sourceLabel,
            items: items,
            totalDurationMs: milliseconds(since: start)
        )
    }

    /// 影音與圖片走檔案表示，避免把大檔整個載進 Extension 記憶體。
    static func prefersFileRepresentation(_ type: String) -> Bool {
        guard let utType = UTType(type) else { return false }
        return utType.conforms(to: .image) || utType.conforms(to: .audiovisualContent)
    }

    @MainActor
    static func load(_ provider: NSItemProvider, type: String, timeout: TimeInterval = loadTimeout) async -> PayloadRecord.Load {
        let start = Date()
        let once = OnceResult()
        let result: Described = await withCheckedContinuation { continuation in
            once.install(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(Described(kind: .timeout, error: "超過 \(Int(timeout)) 秒未回傳"))
            }
            if prefersFileRepresentation(type) {
                _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    // 檔案在 callback 結束後會被刪除，只能在這裡讀大小。
                    if let url {
                        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                        let isImage = UTType(type)?.conforms(to: .image) == true
                        once.resume(Described(kind: .file, preview: url.lastPathComponent, byteCount: size,
                                              imageJPEG: isImage ? ImageDownscale.jpeg(fileURL: url) : nil))
                    } else {
                        once.resume(Described(kind: .error, error: error.map(describe) ?? "nil"))
                    }
                }
            } else {
                provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                    if let error {
                        once.resume(Described(kind: .error, error: describe(error)))
                    } else {
                        once.resume(describe(item: item, typeIdentifier: type))
                    }
                }
            }
        }
        return PayloadRecord.Load(
            typeIdentifier: type,
            kind: result.kind,
            preview: result.preview,
            byteCount: result.byteCount,
            durationMs: milliseconds(since: start),
            error: result.error,
            imageJPEG: result.imageJPEG
        )
    }

    struct Described: Sendable {
        var kind: PayloadRecord.Load.Kind
        var preview: String? = nil
        var byteCount: Int? = nil
        var error: String? = nil
        var imageJPEG: Data? = nil
    }

    static func describe(item: (any NSSecureCoding)?, typeIdentifier: String? = nil) -> Described {
        // URL 型別有時以 Data 送來（純文字、bplist 或 NSKeyedArchiver），盡量解回 URL 方便閱讀。
        if let data = item as? Data, let typeIdentifier, UTType(typeIdentifier)?.conforms(to: .url) == true, let url = decodeURL(data) {
            return Described(kind: .url, preview: truncateURL(url.absoluteString), byteCount: data.count)
        }
        switch item {
        case let url as URL where url.isFileURL:
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return Described(kind: .fileURL, preview: url.lastPathComponent, byteCount: size)
        case let url as URL:
            return Described(kind: .url, preview: truncateURL(url.absoluteString))
        case let text as String:
            return Described(kind: .text, preview: truncate(text), byteCount: text.utf8.count)
        case let data as Data:
            let preview = String(data: data.prefix(previewLimit), encoding: .utf8)
                ?? data.prefix(32).map { String(format: "%02x", $0) }.joined()
            return Described(kind: .data, preview: preview, byteCount: data.count)
        case let dict as NSDictionary:
            return Described(kind: .propertyList, preview: truncate(dict.description))
        case let array as NSArray:
            return Described(kind: .propertyList, preview: truncate(array.description))
        case nil:
            return Described(kind: .object, preview: "nil")
        case let other?:
            return Described(kind: .object, preview: String(describing: type(of: other)))
        }
    }

    static func decodeURL(_ data: Data) -> URL? {
        if let url = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) {
            return url as URL
        }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            if let string = plist as? String { return URL(string: string) }
            if let array = plist as? [Any], let string = array.first as? String { return URL(string: string) }
        }
        if let string = String(data: data, encoding: .utf8), let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil {
            return url
        }
        return nil
    }

    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    /// 網址不能截斷（截斷後就打不開、也解析不出地點）；只擋異常長的。
    static let urlLimit = 4000

    static func truncateURL(_ text: String) -> String {
        text.count > urlLimit ? String(text.prefix(urlLimit)) : text
    }

    static func truncate(_ text: String) -> String {
        text.count > previewLimit ? String(text.prefix(previewLimit)) + "…" : text
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

/// callback 與逾時計時器只有第一個能 resume。
private final class OnceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PayloadInspector.Described, Never>?

    func install(_ continuation: CheckedContinuation<PayloadInspector.Described, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: PayloadInspector.Described) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}
