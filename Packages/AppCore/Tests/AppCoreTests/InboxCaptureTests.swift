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
}
