import AppCore
import Foundation
import Testing
@testable import Features

@MainActor
struct TripStoreTests {
    private let first = Trip(id: UUID(), name: "東京", startDate: "2026-10-01", endDate: "2026-10-05", timeZone: "Asia/Tokyo", revision: 0)
    private let second = Trip(id: UUID(), name: "首爾", startDate: "2026-11-01", endDate: "2026-11-05", timeZone: "Asia/Seoul", revision: 0)

    @Test func startupWaitsForContentBeforeChoosingInitialTab() async {
        let source = ControlledTripSource(trips: [first])
        let store = TripStore(dataSource: source)
        #expect(store.unavailableState == .loading)
        let task = Task { await store.start() }
        await source.waitForSnapshot(1)
        #expect(store.trips == [first])
        #expect(!store.loaded)
        #expect(store.snapshot == nil)
        #expect(store.unavailableState == .loading)
        await source.finish(first)
        await task.value
        #expect(store.loaded)
        #expect(!store.isLoading)
        #expect(store.snapshot?.trip == first)
        #expect(store.errorMessage == nil)
        // 有旅程但沒有每日資料，不應謊報載入失敗。
        #expect(store.unavailableState == .noDays)
    }

    @Test func actualFailureCanRetryWithoutShowingOldErrorWhileWaiting() async {
        let source = ControlledTripSource(trips: [first])
        let store = TripStore(dataSource: source)
        let task = Task { await store.start() }
        await source.waitForSnapshot(1)
        await source.fail(first)
        await task.value
        #expect(store.unavailableState == .failed("讀取失敗"))
        let retry = Task { await store.open(tripID: nil) }
        await source.waitForSnapshot(2)
        #expect(store.unavailableState == .loading)
        await source.finish(first)
        await retry.value
        #expect(store.snapshot?.trip == first)
        #expect(store.errorMessage == nil)
    }

    @Test func emptyListIsNotAnError() async {
        let store = TripStore(dataSource: ControlledTripSource(trips: []))
        await store.start()
        #expect(store.loaded)
        #expect(store.unavailableState == .noTrips)
    }

    @Test func listFailureIsNotMistakenForNoTripsAndRetryClearsIt() async {
        let source = ControlledTripSource(trips: [])
        await source.setListFailure(true)
        let store = TripStore(dataSource: source)
        await store.start()
        #expect(store.unavailableState == .failed("讀取失敗"))
        await source.setListFailure(false)
        await store.open(tripID: nil)
        #expect(store.unavailableState == .noTrips)
    }

    @Test func lateResponseCannotReplaceNewlySelectedTrip() async {
        let source = ControlledTripSource(trips: [first, second])
        let store = TripStore(dataSource: source)
        let startup = Task { await store.start() }
        await source.waitForSnapshot(1)
        await source.finish(first)
        await startup.value
        let oldReload = Task { await store.reload() }
        await source.waitForSnapshot(2)
        store.selectedTripID = second.id
        #expect(store.snapshot == nil)
        #expect(store.unavailableState == .loading)
        await source.waitForSnapshot(3)
        await source.finish(second)
        // 先完成新旅程，再讓舊旅程回應返回。
        await source.finish(first)
        await oldReload.value
        while store.isLoading { await Task.yield() }
        #expect(store.snapshot?.trip == second)
        #expect(store.selectedTripID == second.id)
        #expect(store.errorMessage == nil)
    }
}

private actor ControlledTripSource: TripStoreDataSource {
    enum Failure: Error { case offline }
    let trips: [Trip]
    var listFails = false
    var requests = 0
    var pending: [UUID: CheckedContinuation<TripSnapshot, any Error>] = [:]
    var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    init(trips: [Trip]) { self.trips = trips }
    func setListFailure(_ value: Bool) { listFails = value }
    func myTrips() async throws -> [Trip] {
        if listFails { throw Failure.offline }
        return trips
    }
    func snapshot(of trip: Trip) async throws -> TripSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            pending[trip.id] = continuation
            requests += 1
            let ready = observers.filter { $0.0 <= requests }
            observers.removeAll { $0.0 <= requests }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForSnapshot(_ count: Int) async {
        if requests >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func finish(_ trip: Trip) {
        pending.removeValue(forKey: trip.id)?.resume(returning: TripSnapshot(
            trip: trip, revision: 0, timeline: [], places: [:], saved: [], shopping: []))
    }
    func fail(_ trip: Trip) {
        pending.removeValue(forKey: trip.id)?.resume(throwing: Failure.offline)
    }
}
