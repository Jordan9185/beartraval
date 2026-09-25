import Foundation
import Testing
@testable import AppCore

struct TaxiCardTests {
    func place(_ name: String, local: String?, zh: String?, address: String?, country: String) -> Place {
        Place(id: UUID(), provider: "apple_mapkit", providerPlaceId: "x", name: name, nameLocal: local, address: address,
              latitude: 0, longitude: 0, countryCode: country, nameZh: zh)
    }

    @Test func koreanCardWithChineseCheck() {
        let card = TaxiCard(place: place("Myeongdong Kyoja", local: "명동교자 본점", zh: "明洞餃子本店",
                                         address: "서울특별시 중구 명동10길 29", country: "KR"))
        #expect(card.language == .korean)
        #expect(card.request == "기사님, 이곳으로 가 주세요.")
        #expect(card.requestZh == "司機您好，麻煩載我到這裡。")
        #expect(card.name == "명동교자 본점")
        #expect(card.nameZh == "明洞餃子本店")
        #expect(card.address == "서울특별시 중구 명동10길 29")
        #expect(card.extras.map(\.zh) == ["請按跳表計費。"])
        #expect(card.warnings.isEmpty)
    }

    @Test func japaneseCard() {
        let card = TaxiCard(place: place("お好み村", local: "お好み村", zh: "御好燒村", address: "広島県広島市中区新天地5-13", country: "JP"))
        #expect(card.language == .japanese)
        #expect(card.request == "運転手さん、ここまでお願いします。")
        #expect(card.name == "お好み村" && card.nameZh == "御好燒村")
        #expect(card.warnings.isEmpty)
    }

    @Test func missingAddressAndNonLocalNameAreFlagged() {
        let card = TaxiCard(place: place("廣藏市場", local: nil, zh: "廣藏市場", address: nil, country: "KR"))
        #expect(card.address == nil)
        #expect(card.nameZh == nil, "no duplicate when the only name is Chinese")
        #expect(card.warnings.count == 2)
    }

    @Test func userLabelIsChineseFallback() {
        let card = TaxiCard(place: place("Onion", local: "어니언 성수", zh: nil, address: "서울 성동구", country: "KR"),
                            fallbackChineseLabel: "Onion 咖啡")
        #expect(card.nameZh == "Onion 咖啡")
    }

    @Test func otherCountriesFallBackToEnglish() {
        #expect(TaxiCard.language(for: "TH") == .english)
        #expect(TaxiCard.language(for: "TW") == .chinese)
        #expect(TaxiCard.language(for: nil) == .english)
    }
}
