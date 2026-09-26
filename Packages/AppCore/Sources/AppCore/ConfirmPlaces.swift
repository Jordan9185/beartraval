import Foundation

/// 地點查詢的一個候選（分店）。
public struct PlaceOption: Identifiable, Equatable, Sendable {
    public var draft: PlaceDraft
    public var id: String { draft.providerPlaceId }
    public var name: String { draft.name }
    public var address: String? { draft.address }
    /// 地圖上的店家類型（餐廳、咖啡廳…）；不明時為 nil。
    public var category: SavedCategory?

    public init(draft: PlaceDraft, category: SavedCategory? = nil) {
        self.draft = draft
        self.category = category
    }
}

/// Confirm Places 的一筆（規格 §3.1）。每筆都要有明確決定才能建立 Trip，
/// 候選分店不會自動選定（AC-01）。
public struct ConfirmItem: Identifiable, Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case place(PlaceOption)
        /// 保留為待確認文字 Stop：沒有地點，不參與路線。
        case pendingText
        case remove
    }

    public enum Blocker: Equatable, Sendable {
        case undecided
        case missingDate
        case fixedUnconfirmed
    }

    public var id: Int
    public var stop: ParsedStop
    /// 解析出的日期超出旅程或不明確時為 nil，需使用者指定。
    public var date: String?
    public var candidates: [PlaceOption] = []
    public var searched = false
    /// 地圖搜尋失敗（離線、被節流）：不自動決定，等使用者重新搜尋。
    public var searchFailed = false
    public var decision: Decision?
    /// 疑似固定的 Stop 需使用者確認（nil = 尚未確認）。
    public var fixed: Bool?
    /// 由 App 代為決定（名稱明確相符的地點、航班等不查地圖的項目），使用者仍可更改。
    public var autoDecided = false

    public var label: String {
        stop.placeName ?? stop.sourceExcerpt
    }

    /// 航班等交通段、沒有地名的項目不查地圖，預設保留為文字（使用者仍可改）。
    public var needsSearch: Bool {
        guard stop.placeName != nil else { return false }
        return !(stop.category == "transport" && stop.searchQuery == nil)
    }

    public var blockers: [Blocker] {
        guard let decision else { return [.undecided] }
        if decision == .remove { return [] }
        var result: [Blocker] = []
        if date == nil { result.append(.missingDate) }
        if fixed == nil { result.append(.fixedUnconfirmed) }
        return result
    }
}

public struct ConfirmPlacesState: Equatable, Sendable {
    public var items: [ConfirmItem]
    public var tripDates: [String]

    public init(session: ImportSession, draft: ParseDraft) {
        tripDates = session.tripDates
        var items: [ConfirmItem] = []
        for day in draft.days {
            for stop in day.stops {
                let dateOK = day.date.map(session.tripDates.contains) ?? false
                let date = dateOK && !stop.needsConfirmation.contains(.ambiguousDate) ? day.date : nil
                var item = ConfirmItem(id: items.count, stop: stop, date: date, fixed: stop.fixedSuspected ? nil : false)
                if !item.needsSearch {
                    item.decision = .pendingText
                    item.autoDecided = true
                }
                items.append(item)
            }
        }
        self.items = items
    }

    public var canSubmit: Bool {
        items.allSatisfy { $0.blockers.isEmpty }
    }

    public var remainingCount: Int {
        items.filter { !$0.blockers.isEmpty }.count
    }

    public var undecidedCount: Int {
        items.filter { $0.decision == nil }.count
    }

    public var unconfirmedFixedCount: Int {
        items.filter { $0.decision != .remove && $0.fixed == nil }.count
    }

    /// 需要使用者處理的項目：App 沒代為決定的，或還擋著建立的（日期未定、疑似固定未確認）。
    public var needsAttention: [Int] {
        items.indices.filter { !items[$0].autoDecided || !items[$0].blockers.isEmpty }
    }

    /// 搜尋結果回來後：名稱明確相符就代為選定（規格 §3：已確認／待確認／無法辨識），
    /// 分店不明或有多個相符候選時一律留給使用者（AC-01）。
    public mutating func applySearch(_ lookup: PlaceLookup, at index: Int) {
        switch lookup {
        case .found(let options): applySearchResults(options, at: index)
        case .notFound: applySearchResults([], at: index)
        case .unavailable:
            items[index].searched = true
            items[index].searchFailed = true
        }
    }

    /// 搜尋失敗的項目重新排隊搜尋。
    public mutating func resetFailedSearches() {
        for index in items.indices where items[index].searchFailed {
            items[index].searched = false
            items[index].searchFailed = false
        }
    }

    public var failedSearchCount: Int { items.filter(\.searchFailed).count }

    public mutating func applySearchResults(_ candidates: [PlaceOption], at index: Int) {
        items[index].candidates = candidates
        items[index].searched = true
        items[index].searchFailed = false
        guard items[index].decision == nil else { return }
        if candidates.isEmpty {
            // 無法辨識：不猜，保留為文字，之後可在行程裡再確認（常見於 Apple 地圖沒收錄的韓國小店）。
            items[index].decision = .pendingText
            items[index].autoDecided = true
        } else if let match = PlaceMatch.confident(for: items[index].stop, in: candidates) {
            items[index].decision = .place(match)
            items[index].autoDecided = true
        }
    }

    /// 還沒決定的項目先保留為待確認文字：不猜地點，之後在行程裡再確認（規格 §1）。
    public mutating func keepUndecidedAsText() {
        for index in items.indices where items[index].decision == nil {
            items[index].decision = .pendingText
        }
    }

    /// 使用者按一次確認：只採用名稱唯一且相符的建議地點；其他分店仍逐項確認。
    public var suggestedMatchCount: Int {
        items.indices.filter { suggestedMatch(at: $0) != nil }.count
    }

    public mutating func confirmSuggestedMatches() {
        for index in items.indices {
            guard let match = suggestedMatch(at: index) else { continue }
            items[index].decision = .place(match)
            items[index].autoDecided = true
        }
    }

    private func suggestedMatch(at index: Int) -> PlaceOption? {
        let item = items[index]
        guard item.decision == nil, item.searched, !item.searchFailed, !item.candidates.isEmpty,
              (item.stop.sourceExcerpt.hasPrefix("AI 建議：")
               || item.stop.sourceExcerpt.hasPrefix("使用者指定："))
        else { return nil }
        var stop = item.stop
        stop.confidence = "high"
        return PlaceMatch.confident(for: stop, in: item.candidates)
    }

    /// 使用者一次確認：疑似固定的項目都設為固定。
    public mutating func confirmSuspectedFixed() {
        for index in items.indices where items[index].fixed == nil {
            items[index].fixed = true
        }
    }

    /// 需要先註冊的地點（去重）。
    public var placesToRegister: [PlaceDraft] {
        var seen = Set<String>()
        return items.compactMap { item -> PlaceDraft? in
            guard case .place(let option) = item.decision, seen.insert(option.id).inserted else { return nil }
            return option.draft
        }
    }

    /// 組出 `commit_import` 的內容；`placeIDs` 為 providerPlaceId → 已註冊的 place id。
    /// 同一天維持原文順序。
    public func commitDays(placeIDs: [String: UUID]) -> [ImportDayCommit] {
        precondition(canSubmit, "commitDays requires every item decided")
        var byDate: [String: [StopDraft]] = [:]
        for item in items {
            guard let decision = item.decision, decision != .remove, let date = item.date else { continue }
            var draft = StopDraft(rawLabel: String(item.label.prefix(500)), startTime: item.stop.startTime,
                                  endTime: item.stop.endTime, fixed: item.fixed ?? false)
            if case .place(let option) = decision {
                draft.placeId = placeIDs[option.id]
                draft.dwellMinutes = item.stop.defaultDwellMinutes
            }
            byDate[date, default: []].append(draft)
        }
        return tripDates.compactMap { date in byDate[date].map { ImportDayCommit(date: date, stops: $0) } }
    }
}

/// 判斷搜尋候選是否就是原文寫的那個地點。寧可少選：只有名稱幾乎相同、且只有一個候選相符時才算。
public enum PlaceMatch {
    public static func confident(for stop: ParsedStop, in candidates: [PlaceOption]) -> PlaceOption? {
        guard stop.confidence == "high",
              stop.needsConfirmation.allSatisfy({ $0 == .ambiguousTime }),
              let placeName = stop.placeName else { return nil }
        let targets = [placeName, stop.searchQuery].compactMap { $0 }.map(normalize).filter { $0.count >= 2 }
        func names(_ option: PlaceOption) -> [String] {
            [option.draft.name, option.draft.nameLocal, option.draft.nameZh].compactMap { $0 }.map(normalize)
        }
        let top = candidates.prefix(3)
        // 候選中有同名的其他分店（「Matin Kim 명동점」）就是分店不明，交給使用者（AC-01）。
        let branchMarkers = ["점", "店", "branch"]
        let hasSiblingBranch = top.contains { option in
            names(option).contains { name in
                targets.contains { name != $0 && name.hasPrefix($0) } && branchMarkers.contains { name.hasSuffix($0) }
            }
        }
        if hasSiblingBranch { return nil }
        // 完全同名優先（「大三島」勝過「大三島 盛港」），其次才看相近名稱。
        let exact = top.filter { names($0).contains { targets.contains($0) } }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let close = top.filter { option in names(option).contains { name in targets.contains { similar(name, $0) } } }
        return close.count == 1 ? close[0] : nil
    }

    /// 一方包含另一方，且短的至少是長的六成（「尾道」≈「尾道市」，但「大鳥居」≠「嚴島神社大鳥居」）。
    static func similar(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return long.contains(short) && Double(short.count) >= Double(long.count) * 0.6
    }

    /// 小寫、去掉空白與符號，並把日文新字體換成繁體（厳→嚴、瀬→瀨、広→廣…），
    /// 讓原文寫法和 Apple 地圖回傳的名稱能比對。
    static func normalize(_ text: String) -> String {
        let folded = text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map { Character(kanjiFold[$0] ?? $0) })
    }

    private static let kanjiFold: [Unicode.Scalar: Unicode.Scalar] = {
        let pairs = ["厳嚴", "瀬瀨", "広廣", "国國", "沢澤", "辺邊", "浜濱", "駅驛", "桜櫻", "竜龍", "関關", "学學", "会會",
                     "芸藝", "宝寶", "鉄鐵", "軽輕", "塩鹽", "島島", "県縣", "区區", "橋橋", "戸戶", "図圖", "楽樂", "徳德"]
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        for pair in pairs {
            let scalars = Array(pair.unicodeScalars)
            map[scalars[0]] = scalars[1]
        }
        return map
    }()
}
