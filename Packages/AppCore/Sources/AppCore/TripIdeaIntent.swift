import Foundation

/// 只有目的地與天數的短句，應走 AI 建議樣板；已貼上的逐日行程仍走原文解析。
public enum TripIdeaIntent {
    public static func dayCount(in text: String) -> Int? {
        let pattern = #"(?<![0-9])([0-9]{1,2}|[一二三四五六七八九十兩]+)\s*[天日]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[range])
        let days = Int(value) ?? chineseNumber(value)
        guard let days, (1...14).contains(days) else { return nil }
        return days
    }

    /// 明確天數或逐日行程的最後一天；建立旅程時用來預填結束日期。
    public static func inferredDayCount(in text: String) -> Int? {
        let duration = dayCount(in: text)
        let pattern = #"(?i)(?:\bday\s*([0-9]{1,2})\b|第\s*([0-9]{1,2}|[一二兩三四五六七八九十]+)\s*天)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return duration }
        let range = NSRange(text.startIndex..., in: text)
        let values = regex.matches(in: text, range: range).compactMap { match -> Int? in
            for group in 1...2 {
                guard let valueRange = Range(match.range(at: group), in: text) else { continue }
                let value = String(text[valueRange])
                if let number = Int(value) ?? chineseNumber(value), (1...14).contains(number) { return number }
            }
            return nil
        }
        return [duration, values.max()].compactMap { $0 }.max()
    }

    public static func isRequest(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 120, dayCount(in: trimmed) != nil else { return false }
        // 已有日期、時間或逐日清單時，優先按使用者貼的行程原文解析。
        return !trimmed.contains("\n") && trimmed.range(of: #"\d{1,2}[:：/]\d{1,2}|(?i)day\s*\d+|第\s*[一二三四五六七八九十\d]+\s*天"#,
                                                        options: .regularExpression) == nil
    }

    public static func shouldSuggest(_ text: String, tripDays: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 800, tripDays <= 14 else { return false }
        if trimmed.range(of: #"\d{1,2}[:：/]\d{1,2}|\d{4}-\d{2}-\d{2}|(?i)day\s*\d+|第\s*[一二三四五六七八九十\d]+\s*天|星期[一二三四五六日天]|週[一二三四五六日天]"#,
                         options: .regularExpression) != nil { return false }
        if trimmed.count <= 120, dayCount(in: trimmed) != nil { return true }
        return ["想去", "要去", "想玩", "想吃", "希望去", "、", "，", "\n"]
            .contains(where: trimmed.contains)
    }

    public static func suggestedName(for text: String) -> String? {
        guard let days = inferredDayCount(in: text) else { return nil }
        let cities = ["東京", "大阪", "京都", "首爾", "釜山", "台北", "香港", "曼谷", "新加坡", "巴黎", "倫敦", "紐約", "雪梨", "沖繩", "福岡", "札幌"]
        guard let city = cities.first(where: text.contains) else { return nil }
        return "\(city) \(days) 天"
    }

    public static func suggestedTimeZone(for text: String) -> String? {
        if ["日本", "東京", "大阪", "京都", "沖繩", "福岡", "札幌"].contains(where: text.contains) { return "Asia/Tokyo" }
        if ["韓國", "首爾", "釜山"].contains(where: text.contains) { return "Asia/Seoul" }
        if ["台灣", "台北"].contains(where: text.contains) { return "Asia/Taipei" }
        if text.contains("香港") { return "Asia/Hong_Kong" }
        if text.contains("曼谷") { return "Asia/Bangkok" }
        if text.contains("新加坡") { return "Asia/Singapore" }
        if text.contains("巴黎") { return "Europe/Paris" }
        if text.contains("倫敦") { return "Europe/London" }
        if text.contains("紐約") { return "America/New_York" }
        if text.contains("雪梨") { return "Australia/Sydney" }
        return nil
    }

    private static func chineseNumber(_ value: String) -> Int? {
        let digits: [Character: Int] = ["一": 1, "二": 2, "兩": 2, "三": 3, "四": 4, "五": 5,
                                        "六": 6, "七": 7, "八": 8, "九": 9]
        if value == "十" { return 10 }
        if let ten = value.firstIndex(of: "十") {
            let before = value[..<ten], after = value[value.index(after: ten)...]
            let tens = before.isEmpty ? 1 : before.first.flatMap { digits[$0] }
            guard let tens else { return nil }
            let units = after.isEmpty ? 0 : after.first.flatMap { digits[$0] }
            guard let units else { return nil }
            return tens * 10 + units
        }
        return value.count == 1 ? value.first.flatMap { digits[$0] } : nil
    }
}
