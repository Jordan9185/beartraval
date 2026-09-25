import Foundation

/// S2 Payload Inspector 的一筆分享紀錄（issue #2）。
///
/// 只存截斷後的預覽與大小，不存原始圖片／影片內容。
public struct PayloadRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var osVersion: String
    /// 測試者在分享前選的來源標籤（例如「Threads 單圖」），方便整理矩陣。
    public var sourceLabel: String?
    public var items: [Item]
    public var totalDurationMs: Int

    public struct Item: Codable, Sendable {
        public var attributedTitle: String?
        public var attributedContentText: String?
        public var userInfoKeys: [String]
        public var attachments: [Attachment]
    }

    public struct Attachment: Codable, Sendable {
        public var registeredTypeIdentifiers: [String]
        public var suggestedName: String?
        public var loads: [Load]
    }

    public struct Load: Codable, Sendable {
        public var typeIdentifier: String
        public var kind: Kind
        /// 截斷後的內容預覽（文字、URL、或檔名）。
        public var preview: String?
        public var byteCount: Int?
        public var durationMs: Int
        public var error: String?
        /// 圖片縮圖（JPEG，長邊 1024 px），給購物清單附圖與 AI 辨識用；不寫進 Payload 紀錄。
        public var imageJPEG: Data?

        enum CodingKeys: String, CodingKey {
            case typeIdentifier, kind, preview, byteCount, durationMs, error
        }

        public enum Kind: String, Codable, Sendable {
            case url, fileURL, text, data, file, propertyList, object, error, timeout
        }
    }
}
