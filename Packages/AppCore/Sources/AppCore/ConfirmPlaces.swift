import Foundation

/// 地點查詢的一個候選（分店）。
public struct PlaceOption: Identifiable, Equatable, Sendable {
    public var draft: PlaceDraft
    public var id: String { draft.providerPlaceId }
    public var name: String { draft.name }
    public var address: String? { draft.address }

    public init(draft: PlaceDraft) {
        self.draft = draft
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
    public var decision: Decision?
    /// 疑似固定的 Stop 需使用者確認（nil = 尚未確認）。
    public var fixed: Bool?

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
                if !item.needsSearch { item.decision = .pendingText }
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

    /// 還沒決定的項目先保留為待確認文字：不猜地點，之後在行程裡再確認（規格 §1）。
    public mutating func keepUndecidedAsText() {
        for index in items.indices where items[index].decision == nil {
            items[index].decision = .pendingText
        }
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
