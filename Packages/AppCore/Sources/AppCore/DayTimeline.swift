import Foundation

/// 一天的唯讀時間軸（WP2）。路線在 WP4 才計算，這裡不產生任何分鐘數。
public struct DayTimeline: Identifiable, Codable, Equatable, Sendable {
    public var day: TripDay
    /// 依 sort_order 排序。
    public var stops: [Stop]

    public var id: UUID { day.id }

    public var pendingCount: Int { stops.filter { !$0.isRoutable }.count }
    public var routableCount: Int { stops.filter(\.isRoutable).count }

    public enum RouteStatus: Equatable, Sendable {
        /// 已確認地點少於 2 個，沒有路線可算。
        case notEnoughPlaces
        /// 可計算但尚未計算（WP4）。
        case notCalculated
    }

    public var routeStatus: RouteStatus {
        routableCount < 2 ? .notEnoughPlaces : .notCalculated
    }

    /// 把 Trip 的 Stop 分到各日；沒有 Stop 的日子也保留。
    public static func build(days: [TripDay], stops: [Stop]) -> [DayTimeline] {
        let byDay = Dictionary(grouping: stops, by: \.dayId)
        return days
            .sorted { $0.displayOrder < $1.displayOrder }
            .map { DayTimeline(day: $0, stops: (byDay[$0.id] ?? []).sorted { $0.sortOrder < $1.sortOrder }) }
    }
}
