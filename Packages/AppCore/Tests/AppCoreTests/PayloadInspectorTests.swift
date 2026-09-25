import Foundation
import Testing
@testable import ShareCore

struct PayloadInspectorTests {
    @MainActor @Test func recordsEveryRegisteredTypeOfEveryAttachment() async throws {
        let url = NSItemProvider(object: URL(string: "https://www.threads.net/@someone/post/abc")! as NSURL)
        let text = NSItemProvider(object: "聖水洞 咖啡廳 推薦" as NSString)
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: "分享內文")
        item.attachments = [url, text]

        // CI 的模擬器第一次載入可能很慢；逾時放寬，驗證的是內容而不是速度。
        let record = await PayloadInspector.inspect([item], sourceLabel: "Threads 純文字", timeout: 60)

        #expect(record.sourceLabel == "Threads 純文字")
        let attachments = try #require(record.items.first?.attachments)
        #expect(record.items.first?.attributedContentText == "分享內文")
        #expect(attachments.count == 2)
        // 回傳的實際類別（URL／String／Data）依來源而定，正是 inspector 要記錄的；這裡只驗內容。
        let urlLoad = try #require(attachments[0].loads.first { $0.typeIdentifier == "public.url" })
        #expect(urlLoad.preview == "https://www.threads.net/@someone/post/abc", "kind=\(urlLoad.kind) bytes=\(urlLoad.byteCount ?? -1)")
        #expect(attachments[1].loads.contains { $0.preview == "聖水洞 咖啡廳 推薦" })
    }

    @Test func urlDataIsDecodedFromKeyedArchive() throws {
        let url = URL(string: "https://www.instagram.com/p/xyz/")!
        let archived = try NSKeyedArchiver.archivedData(withRootObject: url as NSURL, requiringSecureCoding: true)
        let described = PayloadInspector.describe(item: archived as NSData, typeIdentifier: "public.url")
        #expect(described.kind == .url)
        #expect(described.preview == url.absoluteString)
    }

    @Test func longTextIsTruncated() {
        let described = PayloadInspector.describe(item: String(repeating: "a", count: 2_000) as NSString)
        #expect(described.preview?.count == PayloadInspector.previewLimit + 1)
        #expect(described.byteCount == 2_000)
    }

    @Test func mediaTypesUseFileRepresentation() {
        #expect(PayloadInspector.prefersFileRepresentation("public.jpeg"))
        #expect(PayloadInspector.prefersFileRepresentation("public.mpeg-4"))
        #expect(!PayloadInspector.prefersFileRepresentation("public.url"))
        #expect(!PayloadInspector.prefersFileRepresentation("public.plain-text"))
    }

    @Test func storeRoundTripsAndSortsNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = PayloadLogStore(directory: dir)
        defer { try? store.removeAll() }
        let older = PayloadRecord(id: UUID(), capturedAt: Date(timeIntervalSince1970: 1_000), osVersion: "t", items: [], totalDurationMs: 1)
        let newer = PayloadRecord(id: UUID(), capturedAt: Date(timeIntervalSince1970: 2_000), osVersion: "t", items: [], totalDurationMs: 1)
        try store.save(older)
        try store.save(newer)

        #expect(try store.all().map(\.id) == [newer.id, older.id])
        let exported = try JSONDecoder.iso8601.decode([PayloadRecord].self, from: Data(contentsOf: store.exportFile()))
        #expect(exported.count == 2)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct PayloadURLTests {
    /// 長網址（例如 Google 地圖分享）不可截斷（審查）。
    @Test func longURLsAreKeptWhole() {
        let long = URL(string: "https://www.google.com/maps/place/" + String(repeating: "a", count: 700))!
        #expect(PayloadInspector.describe(item: long as NSURL, typeIdentifier: "public.url").preview == long.absoluteString)
    }
}

struct PastedLinkTests {
    /// 鍵盤自動大寫會變成「HTTPS://」，仍要認得是連結。
    @Test func detectsLinksRegardlessOfSchemeCase() {
        #expect(ShareAnalysis.urls(in: "HTTPS://maps.apple.com/?ll=37.5512,126.9882&q=N%20Seoul%20Tower").count == 1)
        #expect(ShareAnalysis.urls(in: "去這間 https://naver.me/abc 很好吃").first?.host == "naver.me")
        #expect(ShareAnalysis.urls(in: "光化門").isEmpty)
    }
}

struct ScreenshotTextTests {
    @Test func picksNameBeforeKoreanAddress() {
        let lines = ["9:41", "Instagram", "makmade_official", "MAKMADE 성수", "서울특별시 성동구 연무장길 45", "영업 중", "02-123-4567", "#성수카페"]
        let guess = ScreenshotText.guess(from: lines)
        #expect(guess.address == "서울특별시 성동구 연무장길 45")
        #expect(guess.name == "MAKMADE 성수")
        #expect(!guess.otherLines.contains("9:41") && !guess.otherLines.contains("#성수카페"))
    }

    @Test func recognisesJapaneseAndTaiwanAddresses() {
        #expect(ScreenshotText.isAddress("〒739-0588 広島県廿日市市宮島町1-1"))
        #expect(ScreenshotText.isAddress("台北市信義區松仁路 58 號"))
        #expect(!ScreenshotText.isAddress("厳島神社"))
    }

    @Test func withoutAddressTheFirstMeaningfulLineIsTheName() {
        #expect(ScreenshotText.guess(from: ["12:03", "Follow", "Cafe Layered 연남", "1.2k"]).name == "Cafe Layered 연남")
    }
}

#if canImport(AppKit)
import AppKit

struct ScreenshotOCRTests {
    func render(_ lines: [String]) throws -> Data {
        let size = NSSize(width: 1000, height: 120 * lines.count + 80)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 40, y: size.height - 120 - CGFloat(i) * 110), withAttributes: attrs)
        }
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]))
    }

    /// 在裝置上辨識：畫一張有韓文店名與地址的圖，確認讀得出來並猜對地址。
    @Test func recognisesKoreanShopAndAddress() async throws {
        let lines = await ScreenshotText.recognize(jpeg: try render(["MAKMADE 성수", "서울특별시 성동구 연무장길 45"]))
        let guess = ScreenshotText.guess(from: lines)
        #expect(guess.address?.contains("연무장길") == true, "lines: \(lines)")
        #expect(guess.name?.contains("MAKMADE") == true, "lines: \(lines)")
    }

    /// 中文介面裡的韓國店（IG 截圖常見）。
    @Test func recognisesKoreanShopInChineseInterface() async throws {
        let lines = await ScreenshotText.recognize(jpeg: try render(["明洞必吃！排隊也值得", "명동교자 본점", "서울특별시 중구 명동10길 29", "營業中 · 10:30–21:00"]))
        let guess = ScreenshotText.guess(from: lines)
        #expect(guess.address?.contains("명동10길") == true, "lines: \(lines)")
        #expect(guess.name == "명동교자 본점", "lines: \(lines)")
    }

    @Test func recognisesJapaneseAddress() async throws {
        let lines = await ScreenshotText.recognize(jpeg: try render(["牡蠣屋", "広島県廿日市市宮島町539"]))
        #expect(ScreenshotText.guess(from: lines).address?.contains("宮島町") == true, "lines: \(lines)")
    }
}
#endif

struct KoreanAddressTests {
    @Test func romanizesRoadAddresses() {
        #expect(ScreenshotText.romanizedKoreanAddress("서울특별시 중구 명동10길 29") == "29 Myeongdong 10-gil, Jung-gu, Seoul")
        #expect(ScreenshotText.romanizedKoreanAddress("서울특별시 마포구 성미산로 161-4") == "161-4 Seongmisan-ro, Mapo-gu, Seoul")
        #expect(ScreenshotText.romanizedKoreanAddress("広島県廿日市市宮島町539") == nil)
    }

    @Test func hoursAndTagsAreNoise() {
        #expect(ScreenshotText.isNoise("營業中 · 10:30–21:00"))
        #expect(ScreenshotText.isNoise("#• 10:30-21:00"))
        #expect(!ScreenshotText.isNoise("명동교자 본점"))
    }
}
