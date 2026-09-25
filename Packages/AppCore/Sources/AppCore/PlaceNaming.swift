import Foundation

/// 店名顯示規則：保留原文，旁邊附註繁體中文，例如「명동교자 본점（明洞餃子本店）」。
public enum PlaceNaming {
    static func contains(_ text: String, _ ranges: [ClosedRange<UInt32>]) -> Bool {
        text.unicodeScalars.contains { s in ranges.contains { $0.contains(s.value) } }
    }

    public static func hasHangul(_ t: String) -> Bool { contains(t, [0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F]) }
    public static func hasKana(_ t: String) -> Bool { contains(t, [0x3040...0x309F, 0x30A0...0x30FF]) }
    public static func hasHan(_ t: String) -> Bool { contains(t, [0x4E00...0x9FFF, 0x3400...0x4DBF]) }

    /// 看起來是中文（有漢字、沒有韓文或假名）。
    public static func looksChinese(_ t: String) -> Bool { hasHan(t) && !hasHangul(t) && !hasKana(t) }

    /// 由地圖搜尋回傳的名稱判斷它是原文還是中文翻譯。
    /// 韓國地點若回傳純漢字，是 Apple 的中文譯名；日本地點的漢字可能就是原名，視為原文。
    public static func classify(name: String, countryCode: String?) -> (local: String?, zh: String?) {
        let country = countryCode?.uppercased()
        if hasHangul(name) || hasKana(name) { return (name, nil) }
        if looksChinese(name) {
            if country == "KR" { return (nil, name) }
            if country == "TW" || country == "HK" || country == "MO" || country == "CN" { return (name, name) }
            return (name, nil)
        }
        return (name, nil)
    }

    /// 「原文（中文）」；中文與原文相同或沒有中文時只顯示原文。
    public static func title(original: String, chinese: String?) -> String {
        guard let chinese, !chinese.isEmpty, chinese != original else { return original }
        return "\(original)（\(chinese)）"
    }
}

extension Place {
    /// 原文名稱（外開 Naver／Kakao、在地搜尋用）。
    public var originalName: String { nameLocal ?? name }

    /// 繁體中文名稱：明確的中文名，或供應商名稱本身是中文時。
    public var chineseName: String? {
        if let nameZh, !nameZh.isEmpty { return nameZh }
        return PlaceNaming.looksChinese(name) && name != originalName ? name : nil
    }

    /// 介面顯示：「原文（中文）」。
    public var displayTitle: String { PlaceNaming.title(original: originalName, chinese: chineseName) }

    /// 行程點顯示：地點沒有中文名時，以使用者自己寫的中文標籤當附註。
    public func displayTitle(fallbackChinese label: String?) -> String {
        let zh = chineseName ?? label.flatMap { PlaceNaming.looksChinese($0) ? $0 : nil }
        return PlaceNaming.title(original: originalName, chinese: zh)
    }
}

extension PlaceDraft {
    public var displayTitle: String {
        PlaceNaming.title(original: nameLocal ?? name, chinese: nameZh ?? (PlaceNaming.looksChinese(name) && nameLocal != nil ? name : nil))
    }
}

extension PlaceOption {
    public var displayTitle: String { draft.displayTitle }
}
