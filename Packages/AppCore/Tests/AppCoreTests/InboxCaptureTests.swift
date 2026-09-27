import Foundation
import Testing
@testable import ShareCore

struct InboxCaptureTests {
    @MainActor @Test func keepsTitleOnlyShareWithoutInventingContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = NSExtensionItem()
        item.attributedTitle = NSAttributedString(string: "首爾散步路線")

        let captured = try await InboxCaptureStore(directory: directory).capture([item], ownerHint: nil)
        #expect(captured.title == "首爾散步路線")
        #expect(captured.rawText.isEmpty)
        #expect(captured.assets.isEmpty)
        let abandonedDraft = directory.appending(path: ".abandoned")
        try FileManager.default.createDirectory(at: abandonedDraft, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory.appending(path: captured.id.uuidString).appending(path: "capture.json"),
                                         to: abandonedDraft.appending(path: "capture.json"))
        #expect(InboxCaptureStore(directory: directory).all().count == 1)
    }

    @MainActor @Test func savesFullTextAndDeduplicatesURL() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxCaptureStore(directory: directory)
        let text = "Day 1 明洞\n" + String(repeating: "聖水洞咖啡 ", count: 300)
        let item = NSExtensionItem()
        item.attributedTitle = NSAttributedString(string: "首爾三日遊")
        item.attachments = [
            NSItemProvider(object: URL(string: "https://www.threads.net/@bear/post/123?utm_source=test")! as NSURL),
            NSItemProvider(object: text as NSString),
        ]

        let first = try await store.capture([item], ownerHint: nil)
        #expect(first.rawText == text)
        #expect(first.rawText.count > PayloadInspector.previewLimit)
        #expect(first.canonicalURL == "https://threads.com/@bear/post/123")
        let second = try await store.capture([item], ownerHint: nil)
        #expect(second.id == first.id)
        #expect(store.all().count == 1)

        let user = UUID()
        try store.claim(first, for: user)
        #expect(store.all().first?.ownerHint == user)
        try store.remove(first.id)
        #expect(store.all().isEmpty)
    }

    @MainActor @Test func appInputKeepsTextPhotosAndAccountWithoutTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 合成的單像素 PNG，只驗證來源保存，不作為真實 AI 辨識樣本。
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        let source = directory.appending(path: "source.png")
        try image.write(to: source)
        let store = InboxCaptureStore(directory: directory.appending(path: "captures"))
        let text = "東京五天，想去上野\nhttps://example.com/trip"
        let first = try await store.capture(text: text, imageURLs: [source], ownerHint: nil)
        #expect(first.ownerHint == nil)
        #expect(first.rawText == text)
        #expect(first.assets.count == 1)
        #expect(first.unavailableCount == 0)
        let asset = try #require(first.assets.first)
        #expect(asset.isImage)
        #expect(try Data(contentsOf: store.assetURL(captureID: first.id, asset: asset)) == image)
        let repeated = try await store.capture(text: text, imageURLs: [source], ownerHint: nil)
        #expect(repeated.id == first.id)
        let otherAccount = try await store.capture(text: text, imageURLs: [source], ownerHint: UUID())
        #expect(otherAccount.id != first.id, "未歸屬內容不能自動併到另一帳號")
    }

    @MainActor @Test func sameLinkWithDifferentContentIsPreservedSeparately() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxCaptureStore(directory: directory)
        let first = try await store.capture(text: "https://example.com/post", imageURLs: [], ownerHint: nil)
        let second = try await store.capture(text: "https://example.com/post\n新增店名與購物資訊", imageURLs: [], ownerHint: nil)
        #expect(first.id != second.id)
        #expect(store.all().count == 2)
        #expect(store.all().contains { $0.rawText.contains("新增店名") })
    }

    @MainActor @Test func emptyAppInputDoesNotReportSaved() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxCaptureStore(directory: directory)
        do {
            _ = try await store.capture(text: "  \n", imageURLs: [], ownerHint: nil)
            Issue.record("空白內容不得顯示保存成功")
        } catch InboxCaptureError.emptyPayload {}
        #expect(store.all().isEmpty)
    }

    @Test func imageOnlyShareStillEncodesOptionalRPCArguments() throws {
        let capture = InboxCapture(assets: [])
        let data = try JSONEncoder().encode(InboxSaveParams(capture))
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields.keys.count == 7)
        #expect(fields["p_canonical_url"] is NSNull)
        #expect(fields["p_source_url"] is NSNull)
        #expect(fields["p_title"] is NSNull)
        #expect(fields["p_fingerprint"] as? String == capture.fingerprint)
    }
}
