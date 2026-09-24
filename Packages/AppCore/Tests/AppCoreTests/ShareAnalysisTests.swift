import Foundation
import Testing
@testable import AppCore
@testable import ShareCore

struct ShareAnalysisTests {
    @Test(arguments: [
        ("https://www.threads.net/@cafe/post/ABC?igsh=xyz&utm_source=ig", "https://threads.com/@cafe/post/ABC"),
        ("https://www.instagram.com/p/Cx123/?igsh=MWx0&img_index=2", "https://instagram.com/p/Cx123"),
        ("https://Example.com/a/?utm_medium=x&b=2&a=1#frag", "https://example.com/a?a=1&b=2"),
        ("https://maps.apple.com/?q=Cafe&ll=37.5,127.0", "https://maps.apple.com/?ll=37.5,127.0&q=Cafe"),
    ])
    func canonicalURL(input: String, expected: String) {
        #expect(SourceURL.canonical(URL(string: input)!) == expected)
    }

    @Test func threadsUrlOnlyListsMissingContent() {
        let analysis = ShareAnalysis(ShareContent(urls: [URL(string: "https://www.threads.net/@a/post/1")!], title: "Threads"))
        #expect(analysis.platform == .threads)
        #expect(analysis.missing == [.noPostContent, .noPlaceName])
        #expect(analysis.suggestedQuery == nil)
    }

    @Test func threadsWithTextSuggestsFirstLine() {
        let content = ShareContent(urls: [URL(string: "https://www.threads.net/@a/post/1")!],
                                   texts: ["#首爾咖啡\n어니언 성수 真的好好拍\nhttps://www.threads.net/@a/post/1"])
        let analysis = ShareAnalysis(content)
        #expect(analysis.missing.isEmpty)
        #expect(analysis.suggestedQuery == "어니언 성수 真的好好拍")
    }

    @Test func googleMapsPlaceLink() {
        let hint = MapLink.hint(URL(string: "https://www.google.com/maps/place/Gwangjang+Market/@37.5700,126.9996,17z")!)
        #expect(hint?.name == "Gwangjang Market")
        #expect(hint?.coordinate == Coordinate(latitude: 37.57, longitude: 126.9996))
        let q = MapLink.hint(URL(string: "https://maps.google.com/?q=34.3955,132.4536")!)
        #expect(q?.coordinate == Coordinate(latitude: 34.3955, longitude: 132.4536))
    }

    @Test func appleAndKakaoLinks() {
        let apple = MapLink.hint(URL(string: "https://maps.apple.com/?ll=37.5447,127.0584&q=Onion")!)
        #expect(apple == MapHint(name: "Onion", coordinate: Coordinate(latitude: 37.5447, longitude: 127.0584)))
        let kakao = MapLink.hint(URL(string: "https://map.kakao.com/link/map/%EA%B4%91%EC%9E%A5%EC%8B%9C%EC%9E%A5,37.57,126.9996")!)
        #expect(kakao?.name == "광장시장")
        #expect(kakao?.coordinate == Coordinate(latitude: 37.57, longitude: 126.9996))
    }

    @Test func shortLinkIsReportedWhenNotExpanded() {
        let analysis = ShareAnalysis(ShareContent(urls: [URL(string: "https://maps.app.goo.gl/AbCd")!]))
        #expect(analysis.platform == .googleMaps)
        #expect(analysis.missing.contains(.shortLinkUnresolved))
    }

    @Test func mapHintSuppliesQuery() {
        let analysis = ShareAnalysis(ShareContent(urls: [URL(string: "https://maps.apple.com/?ll=37.5,127.0&q=Onion")!]))
        #expect(analysis.suggestedQuery == "Onion")
        #expect(analysis.missing.isEmpty)
    }

    @Test func contentFromPayloadRecordFindsUrlsAndText() {
        let record = PayloadRecord(id: UUID(), capturedAt: Date(), osVersion: "t", sourceLabel: nil, items: [
            .init(attributedTitle: nil, attributedContentText: "看這間 https://www.instagram.com/p/X1/?igsh=1", userInfoKeys: [], attachments: [
                .init(registeredTypeIdentifiers: ["public.jpeg"], suggestedName: nil, loads: []),
            ]),
        ], totalDurationMs: 1)
        let content = ShareContent(record: record)
        #expect(content.urls.map(\.absoluteString) == ["https://www.instagram.com/p/X1/?igsh=1"])
        #expect(content.hasImage)
        let analysis = ShareAnalysis(content)
        #expect(analysis.canonicalURL == "https://instagram.com/p/X1")
        #expect(analysis.suggestedQuery == "看這間")
        #expect(analysis.missing.isEmpty)
        #expect(ShareAnalysis(ShareContent(texts: ["https://www.instagram.com/p/X1/"])).missing.contains(.noPostContent))
    }
}
