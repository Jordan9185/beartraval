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

    public init(place: Place, fallbackChineseLabel: String? = nil) {
        let lang = Self.language(for: place.countryCode)
        let (request, requestZh, extras) = Self.phrases(lang)
        self.language = lang
        self.request = request
        self.requestZh = requestZh
        self.name = place.originalName
        let zh = place.chineseName ?? fallbackChineseLabel.flatMap { PlaceNaming.looksChinese($0) ? $0 : nil }
        self.nameZh = zh == place.originalName ? nil : zh
        self.address = place.address.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.extras = extras

        var warnings: [String] = []
        if address == nil {
            warnings.append("這個地點沒有地址，司機可能找不到；建議同時出示地圖。")
        }
        if lang == .korean && !PlaceNaming.hasHangul(name) {
            warnings.append("店名不是韓文原文，司機可能看不懂；請以地址為主。")
        }
        if lang == .japanese && !(PlaceNaming.hasKana(name) || PlaceNaming.hasHan(name)) {
            warnings.append("店名不是日文原文，司機可能看不懂；請以地址為主。")
        }
        self.warnings = warnings
    }
}
