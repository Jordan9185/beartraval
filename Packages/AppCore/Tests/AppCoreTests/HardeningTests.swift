import Foundation
import Testing
@testable import AppCore

struct HardeningTests {
    @Test func everyErrorHasAMessage() {
        let errors: [BackendError] = [.unauthenticated, .forbidden, .notFound, .staleRevision, .conflict("DUPLICATE_SAVED"),
                                      .gone("INVITE_EXPIRED"), .gone("INVITE_REVOKED"), .invalid("PLACE_UNRESOLVED"), .other("x")]
        for e in errors { #expect(!e.userMessage.isEmpty) }
        #expect(BackendError.gone("INVITE_REVOKED").userMessage.contains("撤銷"))
        #expect(BackendError.other("offline").isTransient && !BackendError.forbidden.isTransient)
    }

    @Test func unavailableReasonsNeverShowMinutes() {
        for reason in [RouteEstimate.UnavailableReason.notSupportedInRegion, .unconfirmedPlace, .network, .throttled, .unknown] {
            #expect(reason.userMessage.range(of: "[0-9]", options: .regularExpression) == nil)
        }
    }

    @Test func snapshotCacheRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (snapshot, _) = TripSnapshotTests().snapshot()
        let cache = SnapshotCache(directory: dir)
        cache.save(snapshot, at: Date(timeIntervalSince1970: 1_790_000_000))
        let loaded = try #require(cache.load(tripID: snapshot.trip.id))
        #expect(loaded.snapshot == snapshot)
        #expect(loaded.savedAt == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func telemetryPercentilesAndFailures() async {
        let t = Telemetry()
        for ms in [10, 20, 30, 40, 1000] { await t.record("route.walking", latencyMs: ms) }
        await t.record("route.walking", latencyMs: 5, failure: "throttled")
        let s = await t.stats["route.walking"]!
        #expect(s.count == 6)
        #expect(s.failures == ["throttled": 1])
        #expect(s.p50 == 20 || s.p50 == 30)
        #expect(s.p95 == 1000)
    }

    @Test func instrumentedProviderRecords() async {
        let t = Telemetry()
        let a = jp(1), b = jp(2)
        let provider = InstrumentedProvider(FakeProvider(legs([(a, b, 10)])), telemetry: t)
        _ = await provider.travelTime(from: a.coordinate, to: b.coordinate, mode: .walking, departure: Date())
        _ = await provider.travelTime(from: b.coordinate, to: a.coordinate, mode: .walking, departure: Date())
        let s = await t.stats["route.walking"]!
        #expect(s.count == 2 && s.failures == ["unknown": 1])
    }
}
