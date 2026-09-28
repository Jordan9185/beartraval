import AppCore
import Foundation
import Observation
import SwiftUI

/// 旅程清單與內容可分別延遲或失敗；測試可控制回應時機，不依賴網路。
protocol TripStoreDataSource: Sendable {
    func myTrips() async throws -> [Trip]
    func snapshot(of trip: Trip) async throws -> TripSnapshot
}
extension TripRepository: TripStoreDataSource {}

/// Today 與 Map 共用的目前 Trip 資料（同一份 snapshot、同一 revision；AC-02）。
@MainActor
@Observable
public final class TripStore {
    public private(set) var trips: [Trip] = []
    private var selection: UUID?
    public var selectedTripID: UUID? {
        get { selection }
        set {
            guard newValue != selection else { return }
            select(newValue)
            Task { await reload(resubscribe: true) }
        }
    }
    /// 從收藏安排完後，今天分頁要打開的日期。
    public var requestedDayID: UUID?
    public var selectedDayID: UUID? {
        didSet {
            if usesCache, let id = selection, let day = selectedDayID, let owner = cacheOwner {
                UserDefaults.standard.set(day.uuidString, forKey: "selected-day-\(owner)-\(id)")
            }
        }
    }
    private let cacheOwner: UUID?
    public private(set) var snapshot: TripSnapshot?
    public private(set) var myRole: TripRole?
    public private(set) var errorMessage: String?
    public private(set) var loaded = false
    public private(set) var isLoading = false

    enum UnavailableState: Equatable {
        case loading, noTrips, noDays, failed(String)
    }

    var unavailableState: UnavailableState {
        if !loaded || isLoading { return .loading }
        if let errorMessage { return .failed(errorMessage) }
        return trips.isEmpty ? .noTrips : .noDays
    }
    /// 離線時顯示的快取資料時間；nil 表示資料是最新的。
    public private(set) var cachedAt: Date?

    private let repository: any TripStoreDataSource
    private let usesCache: Bool
    private var sync: TripSync?
    private var loadID = UUID()
    private var openID = UUID()
    private var subscriptionID = UUID()

    public init(repository: TripRepository) {
        self.repository = repository
        usesCache = true
        cacheOwner = repository.currentUserID
    }

    init(dataSource: any TripStoreDataSource) {
        repository = dataSource
        usesCache = false
        cacheOwner = nil
    }

    public func start() async {
        await open(tripID: nil)
    }

    private func select(_ id: UUID?) {
        selection = id
        selectedDayID = id.flatMap { trip in cacheOwner.flatMap { owner in
            UserDefaults.standard.string(forKey: "selected-day-\(owner)-\(trip)").flatMap(UUID.init(uuidString:))
        } }
        requestedDayID = nil
        subscriptionID = UUID()
        loadID = UUID()
        snapshot = nil
        cachedAt = nil
        myRole = nil
        errorMessage = nil
        isLoading = true
    }

    /// 建立、加入或刪除旅程後呼叫：重新取得旅程清單。`tripID` 有值時改看這個旅程，
    /// 否則保留目前選的旅程（它已不存在時改選預設旅程）。
    public func open(tripID: UUID?) async {
        let requestID = UUID()
        openID = requestID
        isLoading = true
        errorMessage = nil
        await refreshTrips(requestID: requestID)
        guard openID == requestID else { return }
        let listError = errorMessage
        let target = tripID.flatMap { id in trips.contains { $0.id == id } ? id : nil }
            ?? selectedTripID.flatMap { id in trips.contains { $0.id == id } ? id : nil }
            ?? defaultTrip(trips)?.id
        if target != selectedTripID { select(target) }
        // 清單完成不代表行程完成：首屏必須等到內容或真正的錯誤有結果。
        await reload(resubscribe: true)
        guard openID == requestID else { return }
        if target == nil { errorMessage = listError }
        loaded = true
    }

    private func refreshTrips(requestID: UUID) async {
        do {
            let fresh = try await repository.myTrips()
            guard openID == requestID else { return }
            trips = fresh
            if usesCache, let url = Self.tripsCacheURL {
                try? JSONEncoder().encode(trips).write(to: url)
            }
        } catch {
            guard openID == requestID else { return }
            // 離線：用上次的 Trip 清單。
            if usesCache, let url = Self.tripsCacheURL, let data = try? Data(contentsOf: url) {
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
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        defer { if loadID == requestID { isLoading = false } }
        guard let id = selectedTripID, let trip = trips.first(where: { $0.id == id }) else {
            snapshot = nil
            cachedAt = nil
            myRole = nil
            let previous = sync
            sync = nil
            await previous?.stop()
            return
        }
        do {
            let fresh = try await repository.snapshot(of: trip)
            guard loadID == requestID, selectedTripID == id else { return }
            snapshot = fresh
            cachedAt = nil
            errorMessage = nil
            if usesCache { SnapshotCache.shared()?.save(fresh) }
        } catch {
            guard loadID == requestID, selectedTripID == id else { return }
            // 離線唯讀：顯示最近一次的資料並標示時間（D6）。
            if usesCache, let entry = SnapshotCache.shared()?.load(tripID: trip.id) {
                snapshot = entry.snapshot
                cachedAt = entry.savedAt
            }
            errorMessage = (error as? BackendError)?.userMessage ?? "讀取失敗"
        }
        // Realtime 訂閱不阻擋首屏；內容已完成即可顯示。
        isLoading = false
        loaded = true
        if resubscribe {
            Task { await subscribe(tripID: id) }
        }
    }

    private func subscribe(tripID: UUID) async {
        guard let repository = repository as? TripRepository, selectedTripID == tripID else { return }
        let requestID = UUID()
        subscriptionID = requestID
        let previous = sync
        sync = nil
        await previous?.stop()
        guard selectedTripID == tripID, subscriptionID == requestID else { return }
        let role = try? await repository.myRole(in: tripID)
        guard selectedTripID == tripID, subscriptionID == requestID else { return }
        myRole = role
        let sync = TripSync(tripID: tripID, repository: repository, revision: snapshot?.revision ?? 0) { [weak self] _ in
            Task {
                guard let self, self.selectedTripID == tripID else { return }
                await self.reload()
            }
        }
        self.sync = sync
        await sync.start()
        if subscriptionID != requestID || selectedTripID != tripID { await sync.stop() }
    }
}

/// 今天與地圖沒有資料時：真的還沒有旅程才請使用者建立；有旅程但載入失敗時說明原因並提供重試
/// （不把離線或錯誤誤說成「尚未建立旅程」）。
struct TripUnavailableView: View {
    let store: TripStore
    let systemImage: String
    let goToTrips: () -> Void

    var body: some View {
        switch store.unavailableState {
        case .loading:
            ProgressView("載入中…")
        case .noTrips:
            ContentUnavailableView {
                Label("還沒有旅程", systemImage: systemImage)
            } description: {
                Text("先建立旅程，或用好友傳來的邀請連結加入。")
            } actions: {
                Button("建立旅程", action: goToTrips).buttonStyle(.borderedProminent)
            }
        case .noDays:
            ContentUnavailableView {
                Label("還沒有每日行程", systemImage: systemImage)
            } description: {
                Text("到旅程頁查看或安排行程。")
            } actions: {
                Button("查看旅程", action: goToTrips).buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("無法載入旅程", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重新載入") { Task { await store.open(tripID: nil) } }
            }
        }
    }
}
