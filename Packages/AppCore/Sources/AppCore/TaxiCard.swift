import Foundation

/// 給當地計程車司機看的目的地卡片：當地語言的固定句子 + 店名 + 地址，
/// 並附上繁體中文翻譯讓使用者先確認內容（句子為固定模板，不經 AI 翻譯）。
public struct TaxiCard: Equatable, Sendable {
    public enum Language: String, Sendable {
        case korean = "ko"
        case japanese = "ja"
        case chinese = "zh-Hant"
        case english = "en"
    }

    public var language: Language
    /// 給司機看的請求句（當地語言）。
    public var request: String
    /// 請求句的中文翻譯。
    public var requestZh: String
    /// 目的地名稱（原文）。
    public var name: String
    /// 目的地中文名稱；沒有時為 nil。
    public var nameZh: String?
    /// 地址（原文，司機讀）；沒有時為 nil。
    public var address: String?
    /// 補充句（當地語言 + 中文），例如「請按跳表計費」。
    public var extras: [(local: String, zh: String)]
    /// 給使用者的提醒（中文），例如缺地址。
    public var warnings: [String]
    /// 地址不是當地文字時，用座標以當地語言反查（見 `LocalAddress`）。
    public var latitude: Double?
    public var longitude: Double?
    public var countryCode: String?

    /// 地址還不是司機看得懂的當地文字。
    public var needsLocalAddress: Bool {
        LocalAddress.locale(for: countryCode) != nil && latitude != nil && !(address.map { LocalAddress.isLocal($0, countryCode: countryCode) } ?? false)
    }

    static let foreignAddressWarning = "地址不是當地文字，司機可能看不懂；請以店名或地圖為主。"

    /// 換上反查到的當地文字地址，並拿掉相關提醒。
    public mutating func useLocalAddress(_ local: String) {
        address = local
        warnings.removeAll {
            $0 == Self.foreignAddressWarning || $0.hasPrefix("這個地點沒有地址")
                || $0 == "地址是查得的線索，請先核對分店與地圖位置。"
        }
    }

    public static func == (a: TaxiCard, b: TaxiCard) -> Bool {
        a.language == b.language && a.request == b.request && a.requestZh == b.requestZh && a.name == b.name
            && a.nameZh == b.nameZh && a.address == b.address && a.warnings == b.warnings
            && a.extras.map(\.local) == b.extras.map(\.local) && a.extras.map(\.zh) == b.extras.map(\.zh)
    }

    public static func language(for countryCode: String?) -> Language {
        switch countryCode?.uppercased() {
        case "KR": .korean
        case "JP": .japanese
        case "TW", "HK", "MO": .chinese
        default: .english
        }
    }

    /// 固定句子（當地敬語、請求口吻，不用命令句）與逐句的中文翻譯。
    /// 不加「請跳表」這類可能讓司機覺得被懷疑的補充。
    static func phrases(_ language: Language) -> (request: String, requestZh: String, extras: [(String, String)]) {
        switch language {
        case .korean:
            ("기사님, 안녕하세요. 이곳으로 가 주실 수 있을까요? 감사합니다.",
             "司機您好。可以麻煩您載我到這裡嗎？謝謝您。", [])
        case .japanese:
            ("恐れ入りますが、こちらまでお願いできますでしょうか。よろしくお願いいたします。",
             "不好意思，可以麻煩您載我到這裡嗎？麻煩您了。", [])
        case .chinese:
            ("司機您好，不好意思，可以麻煩您載我到這裡嗎？謝謝您。",
             "司機您好，不好意思，可以麻煩您載我到這裡嗎？謝謝您。", [])
        case .english:
            ("Hello, could you please take me to this place? Thank you very much.",
             "您好，可以麻煩您載我到這個地方嗎？非常感謝。", [])
        }
    }

    public init(place: Place, fallbackChineseLabel: String? = nil, fallbackAddress: String? = nil) {
        let lang = Self.language(for: place.countryCode)
        let (request, requestZh, extras) = Self.phrases(lang)
        self.language = lang
        self.request = request
        self.requestZh = requestZh
        self.name = place.originalName
        let zh = place.chineseName ?? fallbackChineseLabel.flatMap { PlaceNaming.looksChinese($0) ? $0 : nil }
        self.nameZh = zh == place.originalName ? nil : zh
        // 優先用當地文字地址（Apple 回傳的地址會依手機語言變成中文）。
        let localHint = fallbackAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressChoices = [place.addressLocal,
                              localHint.flatMap { LocalAddress.isLocal($0, countryCode: place.countryCode) ? $0 : nil },
                              place.address, localHint]
        self.address = addressChoices.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        self.extras = extras
        self.latitude = place.latitude
        self.longitude = place.longitude
        self.countryCode = place.countryCode

        var warnings: [String] = []
        if address == nil {
            warnings.append("這個地點沒有地址，司機可能找不到；建議同時出示地圖。")
        } else if let address, !LocalAddress.isLocal(address, countryCode: place.countryCode) {
            warnings.append(Self.foreignAddressWarning)
        }
        if let localHint, address == localHint, place.addressLocal != localHint {
            warnings.append("地址是查得的線索，請先核對分店與地圖位置。")
        }
        if lang == .korean && !PlaceNaming.hasHangul(name) {
            warnings.append("店名不是韓文原文，司機可能看不懂；請以地址為主。")
        }
        if lang == .japanese && !(PlaceNaming.hasKana(name) || PlaceNaming.hasHan(name)) {
            warnings.append("店名不是日文原文，司機可能看不懂；請以地址為主。")
        }
        self.warnings = warnings
    }

    /// 還沒在 Apple 地圖定位的地點：可附上查得的地址線索，但不當成已確認座標。
    public init(unlocatedName name: String, countryCode: String?, addressHint: String? = nil) {
        let lang = Self.language(for: countryCode)
        let (request, requestZh, extras) = Self.phrases(lang)
        self.language = lang
        self.request = request
        self.requestZh = requestZh
        self.name = name
        self.nameZh = nil
        let trimmedAddress = addressHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = trimmedAddress?.isEmpty == false ? trimmedAddress : nil
        self.address = address
        self.extras = extras
        self.countryCode = countryCode
        var warnings = address == nil
            ? ["這個地點還沒定位，卡片上沒有地址；建議先用當地地圖查到位置，再給司機看地圖。"]
            : ["地址是查得的線索，地點尚未定位；上車前請在地圖核對店名與地址。"]
        if let address, !LocalAddress.isLocal(address, countryCode: countryCode) {
            warnings.append(Self.foreignAddressWarning)
        }
        if lang == .korean && !PlaceNaming.hasHangul(name) {
            warnings.append("店名不是韓文，司機可能看不懂；請以地址為主。")
        }
        if lang == .japanese && !(PlaceNaming.hasKana(name) || PlaceNaming.hasHan(name)) {
            warnings.append("店名不是日文，司機可能看不懂。")
        }
        self.warnings = warnings
    }
}
