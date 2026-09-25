import Foundation

/// 一個 Trip 在某個 revision 的完整資料。Today、Trip、Map 共用同一份，
/// 確保三頁看到的是同一份正式行程與同一版本（AC-02）。
public struct TripSnapshot: Codable, Equatable, Sendable {
    public var trip: Trip
    public var revision: Int
    public var timeline: [DayTimeline]
    public var places: [UUID: Place]
    public var saved: [SavedEntry]
    public var shopping: [ShoppingEntry]
    public var merchants: [UUID: [MerchantCandidate]]

    public init(trip: Trip, revision: Int, timeline: [DayTimeline], places: [UUID: Place], saved: [SavedEntry],
                shopping: [ShoppingEntry], merchants: [UUID: [MerchantCandidate]] = [:]) {
        self.trip = trip
        self.revision = revision
        self.timeline = timeline
        self.places = places
        self.saved = saved
        self.shopping = shopping
        self.merchants = merchants
    }

    /// 旅程中的今天：每一天用各自的時區判斷（跨國旅程）；不在旅程期間時為第一天。
    public func todayIndex(now: Date = Date()) -> Int {
        timeline.firstIndex { day in
            guard let tz = TimeZone(identifier: day.day.timeZone) else { return false }
            return LocalDate.string(from: now, timeZone: tz) == day.day.localDate
        } ?? 0
    }

    /// 可以試算順路的 Saved：地點已確認、尚未加入行程。
    public var routableSaved: [SavedEntry] {
        saved.filter { $0.isConfirmed && $0.saved.status == .saved && $0.place != nil }
    }

    public func todayShopping(dayIndex: Int) -> [ShoppingEntry] {
        guard timeline.indices.contains(dayIndex) else { return [] }
        return TodayShopping.items(shopping, on: timeline[dayIndex].day.localDate)
    }

    public var shoppingProgress: ShoppingProgress { ShoppingProgress(shopping) }
}

/// 地圖圖層（規格 §3.4）。
public enum MapLayer: String, CaseIterable, Hashable, Sendable {
    case todayRoute, saved, food, shopping, otherDays

    public var title: String {
        switch self {
        case .todayRoute: "今日路線"
        case .saved: "收藏"
        case .food: "美食"
        case .shopping: "購物"
        case .otherDays: "其他天"
        }
    }
}

public struct TripMapPin: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case stop(UUID, order: Int, fixed: Bool)
        case saved(UUID)
        case merchant(itemID: UUID, candidateID: UUID)
    }

    public var id: String
    public var layer: MapLayer
    public var kind: Kind
    public var place: Place
    public var title: String
    /// 已購商品的備選店降權顯示（AC-11）。
    public var dimmed: Bool
}

extension TripSnapshot {
    /// 依圖層產生圖釘；未確認地點沒有座標，不會出現。
    public func pins(dayIndex: Int, layers: Set<MapLayer>) -> [TripMapPin] {
        var pins: [TripMapPin] = []
        for (index, day) in timeline.enumerated() {
            let isToday = index == dayIndex
            let layer: MapLayer = isToday ? .todayRoute : .otherDays
            guard layers.contains(layer) else { continue }
            var order = 0
            for stop in day.stops where stop.isRoutable {
                guard let place = stop.placeId.flatMap({ places[$0] }) else { continue }
                order += 1
                pins.append(TripMapPin(id: "stop-\(stop.id)", layer: layer, kind: .stop(stop.id, order: order, fixed: stop.fixed),
                                   place: place, title: place.displayTitle(fallbackChinese: stop.rawLabel), dimmed: !isToday))
            }
        }
        for entry in routableSaved {
            guard let place = entry.place else { continue }
            let isFood = entry.saved.category == .eat || entry.saved.category == .cafe
            let layer: MapLayer = isFood ? .food : .saved
            guard layers.contains(layer) || (layers.contains(.saved) && isFood && !layers.contains(.food)) else { continue }
            pins.append(TripMapPin(id: "saved-\(entry.id)", layer: layer, kind: .saved(entry.id), place: place, title: entry.title, dimmed: false))
        }
        if layers.contains(.shopping) {
            for entry in shopping {
                for candidate in merchants[entry.id] ?? [] {
                    guard let place = places[candidate.placeId] else { continue }
                    pins.append(TripMapPin(id: "merchant-\(candidate.id)", layer: .shopping,
                                       kind: .merchant(itemID: entry.id, candidateID: candidate.id),
                                       place: place, title: "\(entry.item.name) · \(place.displayTitle)", dimmed: entry.isPurchased))
                }
            }
        }
        return pins
    }
}

extension Coordinate {
    /// 一組地點的中心（搜尋範圍用）。
    public static func center(of places: some Collection<Place>) -> Coordinate? {
        guard !places.isEmpty else { return nil }
        let n = Double(places.count)
        return Coordinate(latitude: places.map(\.latitude).reduce(0, +) / n, longitude: places.map(\.longitude).reduce(0, +) / n)
    }
}

extension TripRepository {
    /// 旅程已確認地點的中心；還沒有地點時為 nil。
    public func center(of tripID: UUID) async -> Coordinate? {
        guard let stops = try? await stops(of: tripID),
              let list = try? await places(ids: Array(Set(stops.compactMap(\.placeId)))) else { return nil }
        return Coordinate.center(of: list)
    }

    /// 一次載入 Trip 的全部資料並記下 revision（載入前後 revision 不同時重試一次）。
    public func snapshot(of trip: Trip) async throws -> TripSnapshot {
        for _ in 0..<2 {
            let before = try await tripRevision(trip.id)
            async let d = days(of: trip.id)
            async let s = stops(of: trip.id)
            async let sv = savedEntries(of: trip.id)
            async let sh = shoppingEntries(of: trip.id)
            let (days, stops, saved, shopping) = try await (d, s, sv, sh)
            var merchantsByItem: [UUID: [MerchantCandidate]] = [:]
            for item in shopping { merchantsByItem[item.id] = try await merchants(of: item.id) }
            let placeIDs = Set(stops.compactMap(\.placeId)).union(merchantsByItem.values.flatMap { $0.map(\.placeId) })
            let placeList = try await places(ids: Array(placeIDs))
            let after = try await tripRevision(trip.id)
            if before == after {
                return TripSnapshot(trip: trip, revision: after, timeline: DayTimeline.build(days: days, stops: stops),
                                    places: Dictionary(uniqueKeysWithValues: placeList.map { ($0.id, $0) }),
                                    saved: saved, shopping: shopping, merchants: merchantsByItem)
            }
        }
        throw BackendError.staleRevision
    }
}
