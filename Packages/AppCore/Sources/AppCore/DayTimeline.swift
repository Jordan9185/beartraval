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

/// 僅核對已知當地時間與停留，不把未知交通當成零分鐘，也不要求地圖座標。
public enum ScheduleTimeReview {
    public struct Issue: Identifiable, Equatable, Sendable {
        public let id: String
        public let message: String
    }
    public static func issues(in stops: [Stop]) -> [Issue] {
        let ordered = stops.sorted { $0.sortOrder < $1.sortOrder }
        var result: [Issue] = []
        for (index, first) in ordered.enumerated() {
            guard let start = clockSeconds(first.startTime) else { continue }
            let end = endSecond(first, start: start)
            if let end, end > 86400 {
                result.append(Issue(id: "overnight:\(first.id)", message: "「\(first.rawLabel)」跨至隔日；請核對隔天行程，尚未計入交通。"))
            }
            for second in ordered.dropFirst(index + 1) {
                guard let next = clockSeconds(second.startTime) else { continue }
                let fixed = first.fixed || second.fixed ? "（包含固定行程）" : ""
                if start > next {
                    result.append(Issue(id: "order:\(first.id):\(second.id)", message: "「\(first.rawLabel)」排在「\(second.rawLabel)」之前，開始時間卻較晚\(fixed)。"))
                } else if let end, end > next {
                    result.append(Issue(id: "overlap:\(first.id):\(second.id)", message: "「\(first.rawLabel)」的結束時間或停留範圍，與「\(second.rawLabel)」重疊\(fixed)。"))
                }
            }
        }
        return result
    }

    public static func unknownTimeCount(in stops: [Stop]) -> Int {
        stops.filter { stop in
            guard let start = clockSeconds(stop.startTime) else { return true }
            return endSecond(stop, start: start) == nil
        }.count
    }
    private static func endSecond(_ stop: Stop, start: Int) -> Int? {
        if let end = clockSeconds(stop.endTime) { return end < start ? end + 86400 : end }
        if let dwell = stop.dwellMinutes, dwell > 0 { return start + dwell * 60 }
        return nil
    }
    private static func clockSeconds(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        if parts.count == 3 { guard let seconds = Int(parts[2]), (0..<60).contains(seconds) else { return nil } }
        return h * 3600 + m * 60 + (parts.count == 3 ? Int(parts[2])! : 0)
    }
}
