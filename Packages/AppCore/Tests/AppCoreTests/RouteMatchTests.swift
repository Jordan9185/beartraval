import Foundation
import Testing
@testable import AppCore

/// 以座標對查表的假供應商；沒有列出的路段視為算不出。
final class FakeProvider: RoutingProvider, @unchecked Sendable {
    let id = RouteProvider.appleMapKit
    private let table: [String: Double]
    private let lock = NSLock()
    private(set) var calls = 0

    init(_ table: [String: Double]) { self.table = table }

    static func key(_ a: Coordinate, _ b: Coordinate) -> String { "\(a.latitude),\(a.longitude)>\(b.latitude),\(b.longitude)" }

    func travelTime(from: Coordinate, to: Coordinate, mode: TravelMode, departure: Date) async -> LegTime {
        lock.withLock { calls += 1 }
        return table[Self.key(from, to)].map(LegTime.minutes) ?? .unavailable(.unknown)
    }
}

/// 測試用地點：日本（避開韓國大眾運輸規則），緯度區分。
func jp(_ n: Double) -> RoutePoint { RoutePoint(coordinate: Coordinate(latitude: 34 + n / 100, longitude: 132.4), countryCode: "JP") }
let kr = RoutePoint(coordinate: Coordinate(latitude: 37.57, longitude: 126.99), countryCode: "KR")

func legs(_ pairs: [(RoutePoint, RoutePoint, Double)]) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: pairs.map { (FakeProvider.key($0.0.coordinate, $0.1.coordinate), $0.2) })
}

func stop(_ p: RoutePoint, start: Int? = nil, dwell: Int? = nil, fixed: Bool = false) -> PlannedStop {
    PlannedStop(id: UUID(), label: "\(p.coordinate.latitude)", point: p, startMinutes: start, dwellMinutes: dwell, fixed: fixed)
}

func plan(_ stops: [PlannedStop], pending: Int = 0) -> DayPlan {
    DayPlan(dayID: UUID(), routeRevision: 3, localMidnight: Date(timeIntervalSince1970: 1_790_000_000), stops: stops, excludedPendingCount: pending)
}

struct RouteMatchTests {
    let a = jp(1), b = jp(2), c = jp(3), x = jp(9)

    @Test func detourIsAddedTravelTimeAtBestMiddlePosition() async {
        let provider = FakeProvider(legs([
            (a, b, 10), (b, c, 10),
            (a, x, 4), (x, b, 8),   // 插在 A-B：4 + 8 − 10 = 2
            (b, x, 9), (x, c, 9),   // 插在 B-C：9 + 9 − 10 = 8
            (x, a, 30), (c, x, 30), // 頭尾
        ]))
        let match = await RouteMatcher(provider: provider).match(RouteCandidate(point: x, dwellMinutes: 30), into: plan([stop(a), stop(b), stop(c)]), mode: .walking)
        let best = try! #require(match.best)
        #expect(best.index == 1)
        #expect(best.addedTravelMinutes == 2)
        #expect(best.addedDwellMinutes == 30)
        #expect(match.routeRevision == 3)
        #expect(match.provider == .appleMapKit)
        if case .matched(_, let all) = match.result { #expect(all.count == 4) }
    }

    @Test func detourNeverNegativeAndRoundsUp() async {
        let provider = FakeProvider(legs([(a, b, 10), (a, x, 3), (x, b, 5.2), (x, a, 50), (b, x, 50)]))
        let best = await RouteMatcher(provider: provider).match(RouteCandidate(point: x, dwellMinutes: 0), into: plan([stop(a), stop(b)]), mode: .driving).best
        #expect(best?.addedTravelMinutes == 0)

        let p2 = FakeProvider(legs([(a, b, 10), (a, x, 5), (x, b, 5.2), (x, a, 50), (b, x, 50)]))
        let best2 = await RouteMatcher(provider: p2).match(RouteCandidate(point: x, dwellMinutes: 0), into: plan([stop(a), stop(b)]), mode: .driving).best
        #expect(best2?.addedTravelMinutes == 1)
    }

    @Test func endpointsCanBeDisallowed() async {
        let provider = FakeProvider(legs([(a, b, 10), (a, x, 20), (x, b, 20), (x, a, 1), (b, x, 1)]))
        let matcher = RouteMatcher(provider: provider)
        let open = await matcher.match(RouteCandidate(point: x, dwellMinutes: 0), into: plan([stop(a), stop(b)]), mode: .walking)
        #expect(open.best?.addedTravelMinutes == 1)
        let hotelDay = await matcher.match(RouteCandidate(point: x, dwellMinutes: 0), into: plan([stop(a), stop(b)]), mode: .walking, allowEndpoints: false)
        #expect(hotelDay.best?.index == 1)
        #expect(hotelDay.best?.addedTravelMinutes == 30)
    }

    /// 沒有已定位 Stop 的日子不可算成 +0 分、也不可被選為最佳日（審查 H2）。
    @Test func dayWithoutLocatedStopsIsUnavailable() async {
        let provider = FakeProvider(legs([(a, b, 10), (a, x, 4), (x, b, 8), (x, a, 30), (b, x, 30)]))
        let matcher = RouteMatcher(provider: provider)
        let empty = await matcher.match(RouteCandidate(point: x, dwellMinutes: 30), into: plan([], pending: 3), mode: .walking)
        let only = try! #require(empty.best)
        #expect(only.index == 0 && only.previousStopID == nil && only.nextStopID == nil)
        #expect(only.addedTravelMinutes == nil, "無法估算，不是 +0 分")
        #expect(empty.excludedPendingCount == 3)
        let busy = await matcher.match(RouteCandidate(point: x, dwellMinutes: 30), into: plan([stop(a), stop(b)]), mode: .walking)
        #expect(RouteMatcher.bestDay([empty, busy])?.dayID == busy.dayID)
    }

    @Test func koreaTransitIsUnavailableWithoutCallingProvider() async {
        let provider = FakeProvider([:])
        let match = await RouteMatcher(provider: provider).match(RouteCandidate(point: kr, dwellMinutes: 30), into: plan([stop(kr), stop(kr)]), mode: .transit)
        #expect(match.result == .unavailable(.notSupportedInRegion))
        #expect(match.best == nil)
        #expect(provider.calls == 0)
    }

    @Test func koreaWalkingStillCallsProvider() async {
        let provider = FakeProvider([:])
        _ = await RouteMatcher(provider: provider).match(RouteCandidate(point: kr, dwellMinutes: 30), into: plan([stop(kr)]), mode: .walking)
        #expect(provider.calls > 0)
    }

    @Test func missingLegMakesThatPositionUnknownNotZero() async {
        // A-X 算不出：插在 A-B 未知；只剩頭尾可用。
        let provider = FakeProvider(legs([(a, b, 10), (x, b, 5), (x, a, 7), (b, x, 12)]))
        let match = await RouteMatcher(provider: provider).match(RouteCandidate(point: x, dwellMinutes: 0), into: plan([stop(a), stop(b)]), mode: .walking)
        guard case .matched(let best, let all) = match.result else { Issue.record("expected match"); return }
        #expect(all.first { $0.index == 1 }?.addedTravelMinutes == nil)
        #expect(best.index == 0)
        #expect(best.addedTravelMinutes == 7)
    }

    @Test func allLegsUnavailableIsRouteUnavailable() async {
        let match = await RouteMatcher(provider: FakeProvider([:])).match(RouteCandidate(point: x, dwellMinutes: 0), into: plan([stop(a), stop(b)]), mode: .walking)
        #expect(match.result == .unavailable(.unknown))
    }

    @Test func fixedConflictIsReportedSeparatelyAndFeasiblePositionPreferred() async {
        // A 09:00 停 30 → B 固定 10:00（A→B 20 分）
        // 插在中間：09:30 + 15 + 停 30 + 20 = 10:35 → 遲到 35 分，路程 +15
        // 插在最後：B→X 25 分，路程 +25，但沒有衝突 → 應選最後（AC-06）
        let s0 = stop(a, start: 9 * 60, dwell: 30)
        let s1 = stop(b, start: 10 * 60, fixed: true)
        let provider = FakeProvider(legs([(a, b, 20), (a, x, 15), (x, b, 20), (b, x, 25), (x, a, 60)]))
        let match = await RouteMatcher(provider: provider).match(RouteCandidate(point: x, dwellMinutes: 30), into: plan([s0, s1]), mode: .walking)
        guard case .matched(let best, let all) = match.result else { Issue.record("expected match"); return }
        #expect(all.first { $0.index == 1 }?.fixedCheck == .conflict(stopID: s1.id, lateMinutes: 35))
        #expect(best.index == 2)
        #expect(best.fixedCheck == .noFixedAfter)
        #expect(best.addedTravelMinutes == 25)
    }

    @Test func slackIsComputedAgainstNextFixedStop() async {
        let s0 = stop(a, start: 9 * 60)
        let s1 = stop(b, start: 11 * 60, fixed: true)
        let provider = FakeProvider(legs([(a, b, 20), (a, x, 10), (x, b, 10)]))
        let match = await RouteMatcher(provider: provider).match(RouteCandidate(point: x, dwellMinutes: 30), into: plan([s0, s1]), mode: .walking, allowEndpoints: false)
        // 09:00 + 10 + 30 + 10 = 09:50 → 餘裕 70
        #expect(match.best?.fixedCheck == .slack(stopID: s1.id, minutes: 70))
    }

    @Test func fixedCheckUnknownWhenPreviousStopHasNoTime() async {
        let s1 = stop(b, start: 11 * 60, fixed: true)
        let provider = FakeProvider(legs([(a, b, 20), (a, x, 10), (x, b, 10)]))
        let match = await RouteMatcher(provider: provider).match(RouteCandidate(point: x, dwellMinutes: 30), into: plan([stop(a), s1]), mode: .walking, allowEndpoints: false)
        #expect(match.best?.fixedCheck == .unknown)
    }

    @Test func baseRouteStatus() async {
        let matcher = RouteMatcher(provider: FakeProvider(legs([(a, b, 10), (b, c, 5.5)])))
        #expect(await matcher.baseRoute(for: plan([stop(a), stop(b), stop(c)]), mode: .walking).status == .complete(totalMinutes: 16))
        #expect(await matcher.baseRoute(for: plan([stop(a), stop(b), stop(x)]), mode: .walking).status == .partial(unavailableLegs: 1))
        #expect(await matcher.baseRoute(for: plan([stop(a)]), mode: .walking).status == .noRoute)
        let korea = await matcher.baseRoute(for: plan([stop(kr), stop(kr)], pending: 2), mode: .transit)
        #expect(korea.status == .unavailable(.notSupportedInRegion))
        #expect(korea.excludedPendingCount == 2)
    }

    @Test func repeatedLegsHitTheCache() async {
        let provider = FakeProvider(legs([(a, b, 10), (a, x, 4), (x, b, 8), (x, a, 5), (b, x, 5)]))
        let matcher = RouteMatcher(provider: provider)
        let day = plan([stop(a), stop(b)])
        _ = await matcher.match(RouteCandidate(point: x, dwellMinutes: 0), into: day, mode: .walking)
        let first = provider.calls
        _ = await matcher.match(RouteCandidate(point: x, dwellMinutes: 0), into: day, mode: .walking)
        #expect(provider.calls == first)
    }

    @Test func manyStopsAreApproximated() async {
        let stops = (0..<14).map { stop(jp(Double($0))) }
        var table: [(RoutePoint, RoutePoint, Double)] = []
        for i in 0..<13 { table.append((jp(Double(i)), jp(Double(i + 1)), 5)) }
        let candidate = jp(6.5)
        for i in 0..<14 { table.append((jp(Double(i)), candidate, 5)); table.append((candidate, jp(Double(i)), 5)) }
        let match = await RouteMatcher(provider: FakeProvider(legs(table))).match(RouteCandidate(point: candidate, dwellMinutes: 0), into: plan(stops), mode: .walking)
        guard case .matched(let best, let all) = match.result else { Issue.record("expected match"); return }
        #expect(all.count == 5)
        #expect(best.approximate)
        #expect([6, 7].contains(best.index))
    }

    @Test func bestDayPrefersFeasibleThenFewestMinutes() {
        func day(_ minutes: Int?, _ check: Insertion.FixedCheck) -> DayMatch {
            let ins = Insertion(index: 0, previousStopID: nil, nextStopID: nil, addedTravelMinutes: minutes, addedDwellMinutes: 0, fixedCheck: check, approximate: false)
            return DayMatch(dayID: UUID(), routeRevision: 0, mode: .walking, provider: .appleMapKit, excludedPendingCount: 0,
                            result: minutes == nil ? .unavailable(.unknown) : .matched(best: ins, all: [ins]))
        }
        let conflict = day(1, .conflict(stopID: UUID(), lateMinutes: 5))
        let feasible = day(9, .noFixedAfter)
        let cheaper = day(4, .slack(stopID: UUID(), minutes: 10))
        let unavailable = day(nil, .unknown)
        #expect(RouteMatcher.bestDay([conflict, feasible, unavailable, cheaper])?.dayID == cheaper.dayID)
        #expect(RouteMatcher.bestDay([unavailable]) == nil)
    }
}
