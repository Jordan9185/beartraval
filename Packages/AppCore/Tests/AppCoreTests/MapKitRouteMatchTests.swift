import Foundation
import Testing
@testable import AppCore

/// 以真的 Apple MapKit 跑 Route Match（WP4 實測）。會發網路請求，設定 BEARTRAVEL_TEST_MAPKIT=1 才執行。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BEARTRAVEL_TEST_MAPKIT"] == "1"))
struct MapKitRouteMatchTests {
    func point(_ lat: Double, _ lng: Double, _ cc: String) -> RoutePoint {
        RoutePoint(coordinate: Coordinate(latitude: lat, longitude: lng), countryCode: cc)
    }

    func day(_ stops: [PlannedStop]) -> DayPlan {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        return DayPlan(dayID: UUID(), routeRevision: 1, localMidnight: LocalDate.midnight("2026-10-01", in: tz)!, stops: stops, excludedPendingCount: 0)
    }

    @Test func hiroshimaWalkingDetour() async {
        // 広島駅 → 原爆ドーム（固定 13:00）；候選：お好み村（本通附近，大致順路）
        let station = PlannedStop(id: UUID(), label: "広島駅", point: point(34.3976, 132.4754, "JP"), startMinutes: 10 * 60, dwellMinutes: 0, fixed: false)
        let dome = PlannedStop(id: UUID(), label: "原爆ドーム", point: point(34.3955, 132.4536, "JP"), startMinutes: 13 * 60, dwellMinutes: 60, fixed: true)
        let matcher = RouteMatcher(provider: AppleMapKitProvider())
        let plan = day([station, dome])
        let base = await matcher.baseRoute(for: plan, mode: .walking)
        let match = await matcher.match(RouteCandidate(point: point(34.3918, 132.4618, "JP"), dwellMinutes: 60), into: plan, mode: .walking)
        print("Hiroshima base:", base.status, "best:", match.best as Any)
        guard case .complete(let total) = base.status else { Issue.record("base \(base.status)"); return }
        #expect(total > 10)
        let best = try! #require(match.best)
        #expect(best.index == 1)
        #expect((best.addedTravelMinutes ?? 99) < 15)
        if case .slack = best.fixedCheck {} else { Issue.record("expected slack, got \(best.fixedCheck)") }
    }

    @Test func seoulTransitUnavailableButWalkingWorks() async {
        let myeongdong = PlannedStop(id: UUID(), label: "명동역", point: point(37.5609, 126.9863, "KR"), startMinutes: nil, dwellMinutes: nil, fixed: false)
        let ddp = PlannedStop(id: UUID(), label: "DDP", point: point(37.5665, 127.0092, "KR"), startMinutes: nil, dwellMinutes: nil, fixed: false)
        let market = RouteCandidate(point: point(37.5700, 126.9996, "KR"), dwellMinutes: 60)
        let matcher = RouteMatcher(provider: AppleMapKitProvider())
        let transit = await matcher.match(market, into: day([myeongdong, ddp]), mode: .transit)
        #expect(transit.result == .unavailable(.notSupportedInRegion))
        let walking = await matcher.match(market, into: day([myeongdong, ddp]), mode: .walking)
        print("Seoul walking best:", walking.best as Any)
        #expect(walking.best?.addedTravelMinutes != nil)
    }
}
