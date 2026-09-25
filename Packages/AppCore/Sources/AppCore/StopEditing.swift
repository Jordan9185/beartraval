import Foundation

/// 修改當日單一行程點：以整天清單重新提交（commit_itinerary），其他行程點原樣保留。
public enum StopEdit: Equatable, Sendable {
    /// 待確認地點 → 使用者選定的地點（不自動選）。保留原本的文字，當作中文附註。
    case resolve(placeID: UUID)
    case rename(String)
    case remove
}

extension DayTimeline {
    /// 套用修改後的整天清單；找不到該行程點時回 nil。
    public func drafts(applying edit: StopEdit, to stopID: UUID) -> [StopDraft]? {
        guard stops.contains(where: { $0.id == stopID }) else { return nil }
        return stops.compactMap { stop -> StopDraft? in
            var draft = StopDraft(stop)
            guard stop.id == stopID else { return draft }
            switch edit {
            case .resolve(let placeID):
                draft.placeId = placeID
            case .rename(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return draft }
                draft.rawLabel = String(trimmed.prefix(500))
            case .remove:
                return nil
            }
            return draft
        }
    }
}

extension BaseRoute {
    /// 從這個行程點出發的那一段（待確認的行程點不在路線上，所以會連到下一個已確認的點）。
    public func leg(from stopID: UUID) -> Leg? {
        legs.first { $0.from == stopID }
    }
}
