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

    private let repository: TripRepository
    private var sync: TripSync?

    public init(repository: TripRepository) {
        self.repository = repository
    }

    public func start() async {
        do {
            trips = try await repository.myTrips()
        } catch {
            errorMessage = "讀取失敗：\(error.localizedDescription)"
        }
        loaded = true
        if selectedTripID == nil { selectedTripID = defaultTrip(trips)?.id } else { await reload(resubscribe: true) }
    }

    private func defaultTrip(_ trips: [Trip]) -> Trip? {
        let today = LocalDate.string(from: Date(), timeZone: .current)
        return trips.filter { $0.endDate >= today }.min { $0.startDate < $1.startDate } ?? trips.first
    }

    public func reload(resubscribe: Bool = false) async {
        guard let id = selectedTripID, let trip = trips.first(where: { $0.id == id }) else { snapshot = nil; return }
        do {
            snapshot = try await repository.snapshot(of: trip)
            errorMessage = nil
        } catch {
            errorMessage = "讀取失敗：\(error.localizedDescription)"
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
