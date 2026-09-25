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
        #expect(card.request == "기사님, 안녕하세요. 이곳으로 가 주실 수 있을까요? 감사합니다.")
        #expect(card.requestZh == "司機您好。可以麻煩您載我到這裡嗎？謝謝您。")
        #expect(card.name == "명동교자 본점")
        #expect(card.nameZh == "明洞餃子本店")
        #expect(card.address == "서울특별시 중구 명동10길 29")
        #expect(card.extras.isEmpty, "no meter reminder that might offend the driver")
        #expect(card.warnings.isEmpty)
    }

    @Test func japaneseCard() {
        let card = TaxiCard(place: place("お好み村", local: "お好み村", zh: "御好燒村", address: "広島県広島市中区新天地5-13", country: "JP"))
        #expect(card.language == .japanese)
        #expect(card.request == "恐れ入りますが、こちらまでお願いできますでしょうか。よろしくお願いいたします。")
        #expect(card.requestZh == "不好意思，可以麻煩您載我到這裡嗎？麻煩您了。")
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

    @Test(arguments: [TaxiCard.Language.korean, .japanese, .chinese, .english])
    func requestsArePoliteNotCommands(language: TaxiCard.Language) {
        let (request, zh, extras) = TaxiCard.phrases(language)
        #expect(extras.isEmpty)
        // 請求口吻：以問句結尾或含敬語，不用「~가 주세요／~してください」這類命令句。
        #expect(!request.contains("가 주세요") && !request.contains("してください"))
        #expect(zh.contains("麻煩您") || zh.contains("可以"))
    }

    @Test func otherCountriesFallBackToEnglish() {
        #expect(TaxiCard.language(for: "TH") == .english)
        #expect(TaxiCard.language(for: "TW") == .chinese)
        #expect(TaxiCard.language(for: nil) == .english)
    }

    @Test func prefersLocalAddressOverChineseOne() {
        var p = place("明洞餃子", local: "명동교자 본점", zh: nil, address: "南韓首爾特別市明洞명동10길", country: "KR")
        let chinese = TaxiCard(place: p)
        #expect(chinese.address == "南韓首爾特別市明洞명동10길")
        #expect(chinese.needsLocalAddress)
        #expect(chinese.warnings.contains(TaxiCard.foreignAddressWarning))

        var fixed = chinese
        fixed.useLocalAddress("서울특별시 중구 명동10길 29")
        #expect(fixed.address == "서울특별시 중구 명동10길 29" && !fixed.warnings.contains(TaxiCard.foreignAddressWarning))

        p.addressLocal = "서울특별시 중구 명동10길 29"
        let local = TaxiCard(place: p)
        #expect(local.address == "서울특별시 중구 명동10길 29")
        #expect(!local.needsLocalAddress && local.warnings.isEmpty)
    }

    @Test func localAddressDetection() {
        #expect(LocalAddress.isLocal("서울특별시 중구 명동10길 29", countryCode: "KR"))
        #expect(!LocalAddress.isLocal("南韓首爾特別市明洞명동10길", countryCode: "KR"))
        #expect(!LocalAddress.isLocal("Myeongdong 10-gil, Seoul", countryCode: "KR"))
        #expect(LocalAddress.isLocal("〒160-0023 東京都新宿区西新宿1-1", countryCode: "JP"))
        #expect(!LocalAddress.isLocal("日本東京都新宿區西新宿1-1", countryCode: "JP"))
        #expect(LocalAddress.isLocal("台北市信義區松仁路 58 號", countryCode: "TW"))
        #expect(LocalAddress.stripCountry("대한민국 서울특별시 명동 명동10길") == "서울특별시 명동 명동10길")
    }
}
