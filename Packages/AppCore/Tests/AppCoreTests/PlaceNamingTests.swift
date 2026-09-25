import Foundation
import Testing
@testable import AppCore

struct PlaceNamingTests {
    func place(name: String, local: String? = nil, zh: String? = nil, country: String? = "KR") -> Place {
        Place(id: UUID(), provider: "apple_mapkit", providerPlaceId: "x", name: name, nameLocal: local, address: nil,
              latitude: 0, longitude: 0, countryCode: country, nameZh: zh)
    }

    @Test func originalWithChineseAnnotation() {
        #expect(place(name: "Myeongdong Kyoja", local: "명동교자 본점", zh: "明洞餃子本店").displayTitle == "명동교자 본점（明洞餃子本店）")
        // 裝置語系為中文時 Apple 回傳的中文譯名也算中文附註。
        #expect(place(name: "廣藏市場", local: "광장시장").displayTitle == "광장시장（廣藏市場）")
    }

    @Test func noDuplicateWhenSameOrMissing() {
        #expect(place(name: "Olive Young", country: "KR").displayTitle == "Olive Young")
        #expect(place(name: "お好み村", local: "お好み村", country: "JP").displayTitle == "お好み村")
        #expect(place(name: "台北101", local: "台北101", zh: "台北101", country: "TW").displayTitle == "台北101")
    }

    @Test func stopLabelIsFallbackAnnotationOnlyWhenChinese() {
        let p = place(name: "Onion", local: "어니언 성수")
        #expect(p.displayTitle(fallbackChinese: "Onion 早午餐") == "어니언 성수（Onion 早午餐）")
        #expect(p.displayTitle(fallbackChinese: "brunch") == "어니언 성수")
        #expect(place(name: "x", local: "명동교자", zh: "明洞餃子").displayTitle(fallbackChinese: "晚餐") == "명동교자（明洞餃子）", "real Chinese name wins")
    }

    @Test(arguments: [
        ("廣藏市場", "KR", nil as String?, "廣藏市場" as String?),
        ("광장시장", "KR", "광장시장", nil),
        ("ユニクロ 紙屋町店", "JP", "ユニクロ 紙屋町店", nil),
        ("広島城", "JP", "広島城", nil),
        ("Olive Young", "KR", "Olive Young", nil),
    ])
    func classifySearchResults(name: String, country: String, local: String?, zh: String?) {
        let r = PlaceNaming.classify(name: name, countryCode: country)
        #expect(r.local == local)
        #expect(r.zh == zh)
    }

    @Test func koreanTranslatedResultShowsChineseOnly() {
        // 只有中文譯名、沒有韓文原名時：原文未知，就顯示中文。
        let draft = PlaceDraft(providerPlaceId: "x", name: "廣藏市場", nameLocal: nil, latitude: 0, longitude: 0, countryCode: "KR", nameZh: "廣藏市場")
        #expect(draft.displayTitle == "廣藏市場")
    }
}
