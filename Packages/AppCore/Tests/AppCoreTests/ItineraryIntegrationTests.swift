import Foundation
import Supabase
import Testing
@testable import AppCore

/// 對本機 Supabase 跑 RPC 整合測試（WP2 完成證據）。
///
///     supabase start
///     BEARTRAVEL_TEST_SUPABASE_URL=http://127.0.0.1:54321 \
///     BEARTRAVEL_TEST_SUPABASE_ANON_KEY=<supabase status 的 anon key> swift test
///
/// 沒設定環境變數時略過。每次以隨機 Email 註冊兩個測試使用者。
@Suite(.enabled(if: IntegrationEnv.config != nil))
struct ItineraryIntegrationTests {
    @Test func commitReadBackStaleAndPermission() async throws {
        let owner = try await IntegrationEnv.signedInRepository()
        let trip = try await owner.createTrip(name: "WP2 integration", startDate: "2026-10-01", endDate: "2026-10-02", timeZone: "Asia/Seoul")
        let days = try await owner.days(of: trip.id)
        #expect(days.count == 2)
        let day = try #require(days.first)
        #expect(day.routeRevision == 0)

        let market = try await owner.upsertPlace(PlaceDraft(
            providerPlaceId: "it-\(UUID().uuidString)", name: "Gwangjang Market", nameLocal: "광장시장",
            latitude: 37.5700, longitude: 126.9996, countryCode: "kr"))
        #expect(market.countryCode == "KR")

        let revision = try await owner.commitItinerary(dayID: day.id, expectedRouteRevision: 0, stops: [
            StopDraft(placeId: market.id, rawLabel: "광장시장", startTime: "10:30", fixed: true),
            StopDraft(rawLabel: "카페 (지점 미정)"),
        ])
        #expect(revision == 1)

        let stops = try await owner.stops(of: trip.id)
        #expect(stops.map(\.rawLabel) == ["광장시장", "카페 (지점 미정)"])
        #expect(stops[0].isRoutable && stops[0].fixed && stops[0].startTime == "10:30:00")
        #expect(stops[1].resolutionStatus == .pendingText && !stops[1].isRoutable)
        #expect(try await owner.places(ids: [market.id]).first?.nameLocal == "광장시장")

        // 過期 revision：被拒且不寫入。
        await #expect(throws: BackendError.staleRevision) {
            try await owner.commitItinerary(dayID: day.id, expectedRouteRevision: 0, stops: [StopDraft(rawLabel: "overwrite")])
        }
        #expect(try await owner.stops(of: trip.id).count == 2)

        // 以目前 revision 重新提交：保留 id 更新、未列出的軟刪除。
        let kept = StopDraft(stops[0])
        #expect(try await owner.commitItinerary(dayID: day.id, expectedRouteRevision: 1, stops: [kept]) == 2)
        let after = try await owner.stops(of: trip.id)
        #expect(after.map(\.id) == [stops[0].id])

        // 非成員：看不到 Trip，也不能寫入。
        let outsider = try await IntegrationEnv.signedInRepository()
        #expect(try await outsider.myTrips().contains { $0.id == trip.id } == false)
        #expect(try await outsider.stops(of: trip.id).isEmpty)
        await #expect(throws: BackendError.forbidden) {
            try await outsider.commitItinerary(dayID: day.id, expectedRouteRevision: 2, stops: [])
        }
    }
}

enum IntegrationEnv {
    static let config: BackendConfig? = {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["BEARTRAVEL_TEST_SUPABASE_URL"].flatMap(URL.init(string:)),
              let key = env["BEARTRAVEL_TEST_SUPABASE_ANON_KEY"], !key.isEmpty else { return nil }
        return BackendConfig(url: url, anonKey: key)
    }()

    static func signedInRepository() async throws -> TripRepository {
        let client = Backend.makeClient(config!, storage: MemoryStorage())
        _ = try await client.auth.signUp(email: "it-\(UUID().uuidString.prefix(8).lowercased())@example.com",
                                         password: UUID().uuidString)
        return TripRepository(client: client)
    }
}

final class MemoryStorage: AuthLocalStorage, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
