import AppCore
import Foundation
import Observation

/// Today 與 Map 共用的目前 Trip 資料（同一份 snapshot、同一 revision；AC-02）。
@MainActor
@Observable
public final class TripStore {
    public private(set) var trips: [Trip] = []
    public var selectedTripID: UUID? {
        didSet { if oldValue != selectedTripID { Task { await reload(resubscribe: true) } } }
    }
    public private(set) var snapshot: TripSnapshot?
    public private(set) var myRole: TripRole?
    public private(set) var errorMessage: String?
    public private(set) var loaded = false
    /// 離線時顯示的快取資料時間；nil 表示資料是最新的。
    public private(set) var cachedAt: Date?

    private let repository: TripRepository
    private var sync: TripSync?

    public init(repository: TripRepository) {
        self.repository = repository
    }

    public func start() async {
        await refreshTrips()
        loaded = true
        if selectedTripID == nil { selectedTripID = defaultTrip(trips)?.id } else { await reload(resubscribe: true) }
    }

    /// 建立、加入或刪除旅程後呼叫：重新取得旅程清單。`tripID` 有值時改看這個旅程，
    /// 否則保留目前選的旅程（它已不存在時改選預設旅程）。
    public func open(tripID: UUID?) async {
        await refreshTrips()
        loaded = true
        let target = tripID.flatMap { id in trips.contains { $0.id == id } ? id : nil }
            ?? selectedTripID.flatMap { id in trips.contains { $0.id == id } ? id : nil }
            ?? defaultTrip(trips)?.id
        if target == selectedTripID {
            await reload(resubscribe: true)
        } else {
            selectedTripID = target
        }
    }

    private func refreshTrips() async {
        do {
            trips = try await repository.myTrips()
            try? JSONEncoder().encode(trips).write(to: Self.tripsCacheURL ?? URL(fileURLWithPath: "/dev/null"))
        } catch {
            // 離線：用上次的 Trip 清單。
            if let url = Self.tripsCacheURL, let data = try? Data(contentsOf: url) {
                trips = (try? JSONDecoder().decode([Trip].self, from: data)) ?? []
            }
            errorMessage = (error as? BackendError)?.userMessage ?? "讀取失敗"
        }
    }

    /// 登出時清掉本機的旅程快取（App Group 內，App 與 Extension 共用）。
    public static func clearCaches() {
        if let url = tripsCacheURL { try? FileManager.default.removeItem(at: url) }
        SnapshotCache.shared()?.removeAll()
    }

    static var tripsCacheURL: URL? {
        AppGroup.containerURL?.appending(path: "trips-cache.json")
    }

    private func defaultTrip(_ trips: [Trip]) -> Trip? {
        let today = LocalDate.string(from: Date(), timeZone: .current)
        return trips.filter { $0.endDate >= today }.min { $0.startDate < $1.startDate } ?? trips.first
    }

    public func reload(resubscribe: Bool = false) async {
        guard let id = selectedTripID, let trip = trips.first(where: { $0.id == id }) else { snapshot = nil; return }
        do {
            let fresh = try await repository.snapshot(of: trip)
            snapshot = fresh
            cachedAt = nil
            errorMessage = nil
            SnapshotCache.shared()?.save(fresh)
        } catch {
            // 離線唯讀：顯示最近一次的資料並標示時間（D6）。
            if let entry = SnapshotCache.shared()?.load(tripID: trip.id) {
                snapshot = entry.snapshot
                cachedAt = entry.savedAt
            }
            errorMessage = (error as? BackendError)?.userMessage ?? "讀取失敗"
        }
        if resubscribe { await subscribe(tripID: id) }
    }

    private func subscribe(tripID: UUID) async {
        await sync?.stop()
        myRole = try? await repository.myRole(in: tripID)
        let sync = TripSync(tripID: tripID, repository: repository, revision: snapshot?.revision ?? 0) { [weak self] _ in
            Task { await self?.reload() }
        }
        self.sync = sync
        await sync.start()
    }
}
