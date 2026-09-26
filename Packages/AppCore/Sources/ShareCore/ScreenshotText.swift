import AppCore
import Foundation
import Vision

/// 從截圖讀出文字（裝置上的 Vision 文字辨識，不上傳、不花費用），
/// 再猜出店名與地址給地點搜尋用。只是建議：使用者仍要從候選中選定地點（規格 §1）。
public enum ScreenshotText {
    /// 依畫面由上到下的文字列。
    /// 一張截圖常混著中文介面與韓文／日文店名；Vision 一次只用一種語言模型，
    /// 所以跑「自動、韓文、日文」三次，同一位置取信心最高的那行合併。
    public static func recognize(jpeg: Data) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var found: [(box: CGRect, text: String, confidence: Float)] = []
            for languages in [nil, ["ko-KR"], ["ja-JP"]] as [[String]?] {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                if let languages { request.recognitionLanguages = languages } else { request.automaticallyDetectsLanguage = true }
                guard (try? VNImageRequestHandler(data: jpeg, options: [:]).perform([request])) != nil else { continue }
                for observation in request.results ?? [] {
                    guard let top = observation.topCandidates(1).first else { continue }
                    let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if let index = found.firstIndex(where: { overlaps($0.box, observation.boundingBox) }) {
                        if top.confidence > found[index].confidence { found[index] = (observation.boundingBox, text, top.confidence) }
                    } else {
                        found.append((observation.boundingBox, text, top.confidence))
                    }
                }
            }
            return found.sorted { $0.box.maxY > $1.box.maxY }.map(\.text)
        }.value
    }

    /// 同一行文字：垂直方向大半重疊、水平方向有交集。
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let vertical = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return vertical > 0.5 * min(a.height, b.height) && a.minX < b.maxX && b.minX < a.maxX
    }

    public struct Guess: Equatable, Sendable {
        public var name: String?
        public var address: String?
        /// 其他可能是店名的文字列（給使用者點選）。
        public var otherLines: [String]
        /// 從關鍵字（含 hashtag）猜的收藏類別；看不出來時為 nil。
        public var category: SavedCategory?
        /// 地址（或截圖內容）看起來是哪個國家（ISO 代碼）；看不出來時為 nil。
        public var country: String?
    }

    /// 中文寫的地名也要認得：台灣人分享的韓國店常寫「首爾明洞…」。
    static let countryHints: [(String, [String])] = [
        ("KR", ["首爾", "首尔", "釜山", "仁川", "大邱", "大田", "光州", "蔚山", "濟州", "济州", "京畿", "江原道", "南韓", "韓國", "韩国",
                "明洞", "弘大", "江南區", "聖水", "東大門", "梨泰院", "Seoul", "Busan", "Jeju", "South Korea"]),
        ("JP", ["東京", "大阪", "京都", "北海道", "沖繩", "沖縄", "福岡", "名古屋", "橫濱", "横浜", "神戶", "神戸", "奈良", "日本",
                "Tokyo", "Osaka", "Kyoto", "Japan"]),
        ("TW", ["台北", "臺北", "新北", "桃園", "台中", "臺中", "台南", "臺南", "高雄", "Taipei", "Taiwan"]),
        ("HK", ["香港", "九龍", "新界", "Hong Kong"]),
    ]

    /// 先看地址（最準），再看整張截圖：韓文就是韓國；再來是城市名；最後才看假名
    /// （台灣貼文常用「の」當「的」，單看假名會誤判成日本）。
    public static func country(from lines: [String], address: String?) -> String? {
        for text in [address, lines.joined(separator: " ")].compactMap({ $0 }) {
            if PlaceNaming.hasHangul(text) { return "KR" }
            if let hit = countryHints.first(where: { $0.1.contains { text.localizedCaseInsensitiveContains($0) } }) { return hit.0 }
            if PlaceNaming.hasKana(text.replacingOccurrences(of: "の", with: "")) { return "JP" }
        }
        return nil
    }

    /// 咖啡要排在美食前面：「咖啡廳美食」這類貼文通常是咖啡廳。
    static let categoryKeywords: [(SavedCategory, [String])] = [
        (.cafe, ["咖啡", "카페", "커피", "カフェ", "喫茶", "珈琲", "cafe", "café", "coffee"]),
        (.eat, ["美食", "必吃", "餐廳", "小吃", "料理", "맛집", "식당", "レストラン", "食堂", "グルメ", "ラーメン", "restaurant"]),
        (.shop, ["購物", "必買", "商店", "百貨", "쇼핑", "ショップ", "shopping"]),
    ]

    static func category(from lines: [String]) -> SavedCategory? {
        let text = lines.joined(separator: " ").lowercased()
        return categoryKeywords.first { $0.1.contains { text.contains($0) } }?.0
    }

    public static func guess(from lines: [String]) -> Guess {
        let address = lines.first(where: isAddress)
        let candidates = lines.filter { !isNoise($0) && $0 != address && !isAddress($0) }
        // 地址前一行通常是店名（地圖、IG 地點頁、名片都是這樣排）。
        var name: String?
        if let address, let index = lines.firstIndex(of: address) {
            name = lines[..<index].reversed().first { candidates.contains($0) }
        }
        // 社群截圖頂端常是「聖水洞美食」搜尋欄；真正店名可能在內嵌圖片的招牌。
        // 優先短的韓文招牌、品牌字樣，再退回第一個有意義的文字列。
        let ranked = candidates.enumerated().sorted {
            let left = venueScore($0.element), right = venueScore($1.element)
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
        name = name ?? ranked.first(where: { venueScore($0) > 0 }) ?? candidates.first
        return Guess(name: name, address: address, otherLines: Array(ranked.filter { $0 != name }.prefix(8)),
                     category: category(from: lines), country: country(from: lines, address: address))
    }

    static func venueScore(_ line: String) -> Int {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"\d{2}/\d{1,2}/\d{1,2}|[>@]|\.com\b"#, options: .regularExpression) != nil { return -20 }
        if text.range(of: #"^(?:韓國|首爾|聖水洞|聖水|明洞|弘大)?\s*(?:美食|必買|必吃|旅遊|購物|咖啡)$"#, options: .regularExpression) != nil { return -20 }
        if text.hasPrefix("Q") || text.hasPrefix("搜尋") || text.hasPrefix("搜索") { return -20 }
        if text.count > 25 || text.contains("！！") || text.contains("!!!") { return -10 }
        let hangul = text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        if hangul >= 2 && text.count <= 20 { return 100 + hangul }
        let latinWords = text.range(of: #"[A-Za-z]{4,}"#, options: .regularExpression) != nil
        if latinWords && text.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil { return 80 }
        if latinWords && text.count <= 20 { return 45 }
        if text.count <= 18 { return 30 }
        return 5
    }

    static func isAddress(_ line: String) -> Bool {
        let patterns = [
            #"(특별시|광역시|[가-힣]+도|[가-힣]+[시군구])\s*.*[가-힣0-9]+(로|길)\s*\d+"#,  // 韓國道路名地址
            #"[가-힣]+(동|읍|면)\s*\d+(-\d+)?"#,                                          // 韓國地號地址
            #"〒?\s*\d{3}-\d{4}"#,                                                         // 日本郵遞區號
            #"(東京都|北海道|大阪府|京都府|.{1,3}[県縣]).*(市|区|區|町|村)"#,                  // 日本都道府縣（含中文寫法）
            #"(首爾|首尔|釜山|仁川|大邱|大田|光州|蔚山|濟州|济州).{0,20}(路|街|洞|里|길|로)\s*\d+"#,  // 中文寫的韓國地址
            #"(市|縣|區).*(路|街|道|巷).*\d+\s*號"#,                                        // 台灣
            #"\d+\s+[A-Za-z .]+(Street|St\.?|Road|Rd\.?|Avenue|Ave\.?|-ro|-gil)\b"#,         // 英文
        ]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    /// 截圖裡常見、但不是店名的東西：時間、狀態列、按鈕字、數字、帳號、網址、電話。
    static func isNoise(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.count < 2 || text.count > 40 { return true }
        if text.range(of: #"^\d{1,2}:\d{2}(?:\s|$)"#, options: .regularExpression) != nil { return true }
        if text.hasPrefix("#") || text.hasPrefix("@") || text.lowercased().hasPrefix("http") || text.contains("www.") { return true }
        if text.range(of: #"^[\d\s:.,/%+\-()]+$"#, options: .regularExpression) != nil { return true }  // 時間、數字、電話
        if text.range(of: #"^(\+?\d[\d\s\-]{6,})$"#, options: .regularExpression) != nil { return true }
        // 營業時間（10:30–21:00）、「#•」這類標籤殘字。
        if text.range(of: #"\d{1,2}:\d{2}\s*[-–~〜]\s*\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return true }
        if text.hasPrefix("#") || text.hasPrefix("＃") { return true }
        let ui = ["Instagram", "Threads", "Trip.com", "追蹤", "Follow", "讚", "留言", "分享", "查看翻譯", "Like", "Reply", "Share",
                  "營業中", "Open", "Closed", "路線", "Directions", "Call", "撥打", "網站", "Website", "儲存", "Save",
                  "評論", "Reviews", "相片", "Photos", "영업 중", "길찾기", "저장", "공유", "리뷰", "営業中", "ルート", "保存"]
        return ui.contains { text.caseInsensitiveCompare($0) == .orderedSame }
    }

    /// 韓國道路名地址的羅馬拼音寫法（「29 Myeongdong 10-gil, Jung-gu, Seoul」）。
    /// Apple 地圖找不到韓文地址，但認得這種寫法；不是韓國地址時回 nil。
    public static func romanizedKoreanAddress(_ address: String) -> String? {
        let pattern = #"(?:([가-힣]+?)(?:특별시|광역시|특별자치시|시))?\s*(?:([가-힣]+?)(구|군))?\s*([가-힣]+?)\s*(\d*)\s*(로|길)\s*(\d+(?:-\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let range = Range(m.range(at: i), in: address), !range.isEmpty else { return nil }
            return String(address[range])
        }
        func roman(_ hangul: String) -> String {
            let latin = hangul.applyingTransform(StringTransform("Hangul-Latin"), reverse: false) ?? hangul
            return latin.replacingOccurrences(of: "-", with: "").capitalized
        }
        guard let roadBase = group(4), let suffix = group(6), let number = group(7) else { return nil }
        let roadNumber = group(5).map { " \($0)" } ?? ""
        var road = roman(roadBase) + roadNumber + (suffix == "로" ? "-ro" : "-gil")
        road = road.replacingOccurrences(of: "  ", with: " ")
        var parts = ["\(number) \(road)"]
        if let district = group(2), let kind = group(3) { parts.append(roman(district) + (kind == "구" ? "-gu" : "-gun")) }
        if let city = group(1) { parts.append(roman(city)) }
        return parts.joined(separator: ", ")
    }
}
