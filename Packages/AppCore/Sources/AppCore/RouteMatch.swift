import Foundation

/// 已確認地點的 Stop，進路線計算用。`pending_text` Stop 不會出現在這裡（規格 §1）。
public struct PlannedStop: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var point: RoutePoint
    /// 當地時間，午夜起算的分鐘數。
    public var startMinutes: Int?
    public var dwellMinutes: Int?
    public var fixed: Bool

    public init(id: UUID, label: String, point: RoutePoint, startMinutes: Int?, dwellMinutes: Int?, fixed: Bool) {
        self.id = id
        self.label = label
        self.point = point
        self.startMinutes = startMinutes
        self.dwellMinutes = dwellMinutes
        self.fixed = fixed
    }
}

/// 一天的路線計算輸入。
public struct DayPlan: Sendable {
    public var dayID: UUID
    public var routeRevision: Int
    /// 旅行地當地的午夜；Stop 的分鐘數以此為基準換算出發時間。
    public var localMidnight: Date
    public var stops: [PlannedStop]
    /// 被排除的待確認 Stop 數，結果中註明。
    public var excludedPendingCount: Int

    public init(dayID: UUID, routeRevision: Int, localMidnight: Date, stops: [PlannedStop], excludedPendingCount: Int) {
        self.dayID = dayID
        self.routeRevision = routeRevision
        self.localMidnight = localMidnight
        self.stops = stops
        self.excludedPendingCount = excludedPendingCount
    }

    /// 沒有時間資訊時，以當地 10:00 作為查詢時段。
    static let defaultDepartureMinutes = 10 * 60

    func date(minutes: Double) -> Date {
        localMidnight.addingTimeInterval(minutes * 60)
    }

    /// 從第 i 個 Stop 出發的時間（分鐘）；沒有開始時間時用預設時段。
    func departureMinutes(from i: Int) -> Double {
        guard let start = stops[i].startMinutes else { return Double(Self.defaultDepartureMinutes) }
        return Double(start + (stops[i].dwellMinutes ?? 0))
    }
}

/// 一天的 Base Route，綁定 route_revision 與供應商（AC-02 可追溯）。
public struct BaseRoute: Equatable, Sendable {
    public struct Leg: Equatable, Sendable {
        public var from: UUID
        public var to: UUID
        public var time: LegTime
    }

    public var dayID: UUID
    public var routeRevision: Int
    public var mode: TravelMode
    public var provider: RouteProvider
    public var legs: [Leg]
    public var excludedPendingCount: Int

    public enum Status: Equatable, Sendable {
        /// 已確認地點少於 2 個。
        case noRoute
        case complete(totalMinutes: Int)
        /// 部分路段算不出，不輸出總分鐘數。
        case partial(unavailableLegs: Int)
        case unavailable(RouteEstimate.UnavailableReason)
    }

    public var status: Status {
        if legs.isEmpty { return .noRoute }
        let known = legs.compactMap(\.time.minutes)
        if known.count == legs.count { return .complete(totalMinutes: Int(known.reduce(0, +).rounded(.up))) }
        if known.isEmpty { return .unavailable(Self.dominantReason(legs.map(\.time))) }
        return .partial(unavailableLegs: legs.count - known.count)
    }

    static func dominantReason(_ times: [LegTime]) -> RouteEstimate.UnavailableReason {
        let reasons = times.compactMap { time -> RouteEstimate.UnavailableReason? in
            if case .unavailable(let r) = time { r } else { nil }
        }
        return reasons.contains(.notSupportedInRegion) ? .notSupportedInRegion : (reasons.first ?? .unknown)
    }
}

/// 候選地點插入某個位置後的結果。路程、停留、固定行程餘裕三者分開（規格 §4.1）。
public struct Insertion: Equatable, Sendable {
    /// 插在第 `index` 個 Stop 之前（等於 Stop 數時為最後）。
    public var index: Int
    public var previousStopID: UUID?
    public var nextStopID: UUID?
    /// 增加的路程分鐘；任一段算不出時為 nil（不編造數字）。
    public var addedTravelMinutes: Int?
    public var addedDwellMinutes: Int
    public var fixedCheck: FixedCheck
    /// Stop 很多時只精算部分位置。
    public var approximate: Bool

    public enum FixedCheck: Equatable, Sendable {
        case noFixedAfter
        case slack(stopID: UUID, minutes: Int)
        case conflict(stopID: UUID, lateMinutes: Int)
        /// 缺時間或路段算不出，無法判斷。
        case unknown
    }

    var feasibilityRank: Int {
        switch fixedCheck {
        case .noFixedAfter, .slack: 0
        case .unknown: 1
        case .conflict: 2
        }
    }

    var slackForTieBreak: Int {
        switch fixedCheck {
        case .slack(_, let m): m
        case .noFixedAfter: .max
        default: .min
        }
    }

    /// 可行優先，再比路程最少，同分取餘裕較大（§4.2 第 6 點）。
    static func isBetter(_ a: Insertion, than b: Insertion) -> Bool {
        if a.feasibilityRank != b.feasibilityRank { return a.feasibilityRank < b.feasibilityRank }
        let am = a.addedTravelMinutes ?? .max, bm = b.addedTravelMinutes ?? .max
        if am != bm { return am < bm }
        return a.slackForTieBreak > b.slackForTieBreak
    }
}

public struct DayMatch: Equatable, Sendable {
    public var dayID: UUID
    public var routeRevision: Int
    public var mode: TravelMode
    public var provider: RouteProvider
    public var excludedPendingCount: Int
    public var result: Result

    public enum Result: Equatable, Sendable {
        case matched(best: Insertion, all: [Insertion])
        /// 所有位置都算不出：`ROUTE_UNAVAILABLE`，不輸出分鐘數（AC-14）。
        case unavailable(RouteEstimate.UnavailableReason)
    }

    public var best: Insertion? {
        if case .matched(let best, _) = result { best } else { nil }
    }
}

public struct RouteCandidate: Sendable {
    public var point: RoutePoint
    public var dwellMinutes: Int

    public init(point: RoutePoint, dwellMinutes: Int) {
        self.point = point
        self.dwellMinutes = dwellMinutes
    }
}

public struct RouteMatcher: Sendable {
    let provider: RegionAwareProvider
    let cache: TravelTimeCache
    /// 超過此 Stop 數時只精算直線排序前 `approximateTopPositions` 個位置。
    public var maxExactStops = 12
    public var approximateTopPositions = 5

    public init(provider: any RoutingProvider, cache: TravelTimeCache = TravelTimeCache()) {
        self.provider = RegionAwareProvider(provider)
        self.cache = cache
    }

    func leg(_ from: RoutePoint, _ to: RoutePoint, _ mode: TravelMode, _ departure: Date) async -> LegTime {
        await cache.value(from: from, to: to, mode: mode, departure: departure, using: provider)
    }

    public func baseRoute(for day: DayPlan, mode: TravelMode) async -> BaseRoute {
        var legs: [BaseRoute.Leg] = []
        for i in day.stops.indices.dropLast() {
            let time = await leg(day.stops[i].point, day.stops[i + 1].point, mode, day.date(minutes: day.departureMinutes(from: i)))
            legs.append(.init(from: day.stops[i].id, to: day.stops[i + 1].id, time: time))
        }
        return BaseRoute(dayID: day.dayID, routeRevision: day.routeRevision, mode: mode, provider: provider.id,
                         legs: legs, excludedPendingCount: day.excludedPendingCount)
    }

    /// `allowEndpoints` 為 false 時（當日以住宿為起訖，決策 D9）只插在中間。
    public func match(_ candidate: RouteCandidate, into day: DayPlan, mode: TravelMode, allowEndpoints: Bool = true) async -> DayMatch {
        let stops = day.stops
        let n = stops.count
        let base = await baseRoute(for: day, mode: mode)
        // 沒有已定位的 Stop 時沒有路線可比：仍可排為當天第一站，但路程是「無法估算」，
        // 不可當成「+0 分」而被選為最佳日（規格 §1、審查 H2）。
        guard n > 0 else {
            let only = Insertion(index: 0, previousStopID: nil, nextStopID: nil, addedTravelMinutes: nil,
                                 addedDwellMinutes: candidate.dwellMinutes, fixedCheck: .noFixedAfter, approximate: false)
            return DayMatch(dayID: day.dayID, routeRevision: day.routeRevision, mode: mode, provider: provider.id,
                            excludedPendingCount: day.excludedPendingCount, result: .matched(best: only, all: [only]))
        }

        var positions = Array(0...n)
        if !allowEndpoints && n >= 2 { positions = Array(1...(n - 1)) }
        var approximate = false
        if n > maxExactStops {
            approximate = true
            positions = Array(positions.sorted { straightDetour($0, candidate, stops) < straightDetour($1, candidate, stops) }
                .prefix(approximateTopPositions))
        }

        var insertions: [Insertion] = []
        for k in positions {
            insertions.append(await insertion(at: k, candidate: candidate, day: day, base: base, mode: mode, approximate: approximate))
        }

        let result: DayMatch.Result
        let known = insertions.filter { $0.addedTravelMinutes != nil }
        if let best = known.min(by: { Insertion.isBetter($0, than: $1) }) {
            result = .matched(best: best, all: insertions)
        } else {
            result = .unavailable(await unavailableReason(candidate, day: day, mode: mode, base: base))
        }
        return DayMatch(dayID: day.dayID, routeRevision: day.routeRevision, mode: mode, provider: provider.id,
                        excludedPendingCount: day.excludedPendingCount, result: result)
    }

    /// 各日最佳結果中，可行優先、路程最少者（§4.2 第 7 點）。
    public static func bestDay(_ matches: [DayMatch]) -> DayMatch? {
        matches.filter { $0.best != nil }.min { Insertion.isBetter($0.best!, than: $1.best!) }
    }

    private func insertion(at k: Int, candidate: RouteCandidate, day: DayPlan, base: BaseRoute,
                           mode: TravelMode, approximate: Bool) async -> Insertion {
        let stops = day.stops
        let prev = k > 0 ? stops[k - 1] : nil
        let next = k < stops.count ? stops[k] : nil
        let depPrev = k > 0 ? day.departureMinutes(from: k - 1) : Double(DayPlan.defaultDepartureMinutes)

        var toC: LegTime = .minutes(0)
        if let prev { toC = await leg(prev.point, candidate.point, mode, day.date(minutes: depPrev)) }
        let depC = depPrev + (toC.minutes ?? 0) + Double(candidate.dwellMinutes)
        var fromC: LegTime = .minutes(0)
        if let next { fromC = await leg(candidate.point, next.point, mode, day.date(minutes: depC)) }

        var added: Int?
        if let a = toC.minutes, let b = fromC.minutes {
            var delta = a + b
            if prev != nil && next != nil {
                if let original = base.legs[k - 1].time.minutes { delta -= original } else { delta = .nan }
            }
            if !delta.isNaN { added = max(0, Int(delta.rounded(.up))) }
        }

        let check = fixedCheck(k: k, day: day, base: base, toC: toC, fromC: fromC, candidate: candidate)
        return Insertion(index: k, previousStopID: prev?.id, nextStopID: next?.id, addedTravelMinutes: added,
                         addedDwellMinutes: candidate.dwellMinutes, fixedCheck: check, approximate: approximate)
    }

    /// 插入後模擬到下一個有時間的固定 Stop，算出餘裕或遲到分鐘。
    /// 彈性 Stop 的時間不檢查，只累加停留（§4.2 第 5 點）。
    private func fixedCheck(k: Int, day: DayPlan, base: BaseRoute, toC: LegTime, fromC: LegTime,
                            candidate: RouteCandidate) -> Insertion.FixedCheck {
        let stops = day.stops
        guard let fixedIndex = stops.indices.first(where: { $0 >= k && stops[$0].fixed && stops[$0].startMinutes != nil }) else {
            return .noFixedAfter
        }
        guard k > 0, let prevStart = stops[k - 1].startMinutes else { return .unknown }
        guard let a = toC.minutes, let b = fromC.minutes else { return .unknown }

        var arrival = Double(prevStart + (stops[k - 1].dwellMinutes ?? 0)) + a + Double(candidate.dwellMinutes) + b
        var j = k
        while j < fixedIndex {
            guard let legTime = base.legs[j].time.minutes else { return .unknown }
            arrival += Double(stops[j].dwellMinutes ?? 0) + legTime
            j += 1
        }
        let slack = Double(stops[fixedIndex].startMinutes!) - arrival
        return slack >= 0
            ? .slack(stopID: stops[fixedIndex].id, minutes: Int(slack.rounded(.down)))
            : .conflict(stopID: stops[fixedIndex].id, lateMinutes: Int((-slack).rounded(.up)))
    }

    private func unavailableReason(_ candidate: RouteCandidate, day: DayPlan, mode: TravelMode, base: BaseRoute) async -> RouteEstimate.UnavailableReason {
        if mode == .transit && (candidate.point.isInKorea || day.stops.contains { $0.point.isInKorea }) {
            return .notSupportedInRegion
        }
        return BaseRoute.dominantReason(base.legs.map(\.time))
    }

    private func straightDetour(_ k: Int, _ c: RouteCandidate, _ stops: [PlannedStop]) -> Double {
        let p = k > 0 ? stops[k - 1].point.coordinate : nil
        let q = k < stops.count ? stops[k].point.coordinate : nil
        let a = p.map { $0.straightLineMeters(to: c.point.coordinate) } ?? 0
        let b = q.map { c.point.coordinate.straightLineMeters(to: $0) } ?? 0
        let original = (p != nil && q != nil) ? p!.straightLineMeters(to: q!) : 0
        return a + b - original
    }
}
