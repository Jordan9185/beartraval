import Foundation
import Testing
@testable import AppCore

struct TripSnapshotTests {
    let tripID = UUID()

    func place(_ name: String) -> Place {
        Place(id: UUID(), provider: "apple_mapkit", providerPlaceId: name, name: name, nameLocal: nil, address: nil, latitude: 37.5, longitude: 127, countryCode: "KR")
    }

    func snapshot() -> (TripSnapshot, [Place]) {
        let p = [place("A"), place("B"), place("C"), place("Cafe"), place("Store")]
        let d1 = TripDay(id: UUID(), tripId: tripID, localDate: "2026-10-01", transportMode: .walking, displayOrder: 0, routeRevision: 1, timeZone: "Asia/Seoul")
        let d2 = TripDay(id: UUID(), tripId: tripID, localDate: "2026-10-02", transportMode: .walking, displayOrder: 1, routeRevision: 0, timeZone: "Asia/Seoul")
        func stop(_ day: TripDay, _ order: Int, _ place: Place?, fixed: Bool = false) -> Stop {
            Stop(id: UUID(), tripId: tripID, dayId: day.id, placeId: place?.id, rawLabel: place?.name ?? "pending",
                 resolutionStatus: place == nil ? .pendingText : .resolved, startTime: nil, endTime: nil, dwellMinutes: nil,
                 fixed: fixed, kind: .standard, sortOrder: order, revision: 0)
        }
        let timeline = [DayTimeline(day: d1, stops: [stop(d1, 0, p[0], fixed: true), stop(d1, 1, nil), stop(d1, 2, p[1])]),
                        DayTimeline(day: d2, stops: [stop(d2, 0, p[2])])]
        let cafe = SavedEntry(saved: SavedPlace(id: UUID(), tripId: tripID, placeId: p[3].id, rawLabel: "Cafe", category: .cafe, sourceId: nil, addedBy: UUID(), status: .saved),
                              place: p[3], source: nil, interestedUserIDs: [])
        let unconfirmed = SavedEntry(saved: SavedPlace(id: UUID(), tripId: tripID, placeId: nil, rawLabel: "?", category: .place, sourceId: nil, addedBy: UUID(), status: .saved),
                                     place: nil, source: nil, interestedUserIDs: [])
        let item = ShoppingItem(id: UUID(), tripId: tripID, name: "ReFa", addedBy: UUID())
        let bought = ShoppingEntry(item: item, interestedUserIDs: [], events: [PurchaseEvent(id: 1, itemId: item.id, actorId: UUID(), type: .purchased, createdAt: Date())])
        let merchant = try! JSONDecoder.withISO.decode(MerchantCandidate.self, from: Data("""
            {"id":"\(UUID())","item_id":"\(item.id)","place_id":"\(p[4].id)","evidence_type":"poi_category","evidence_url":null,"evidence_note":null,"expires_at":"2030-01-01T00:00:00Z","inventory_status":"unknown"}
            """.utf8))
        let places = Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0) })
        return (TripSnapshot(trip: Trip(id: tripID, name: "Seoul", startDate: "2026-10-01", endDate: "2026-10-02", timeZone: "Asia/Seoul", revision: 7),
                             revision: 7, timeline: timeline, places: places, saved: [cafe, unconfirmed], shopping: [bought],
                             merchants: [item.id: [merchant]]), p)
    }

    @Test func todayUsesTripTimeZone() {
        let (s, _) = snapshot()
        // 2026-10-01 16:00 UTC = 首爾 10/02 01:00
        #expect(s.todayIndex(now: Date(timeIntervalSince1970: 1_790_870_400)) == 1)
        #expect(s.todayIndex(now: Date(timeIntervalSince1970: 1_700_000_000)) == 0, "outside the trip falls back to day 1")
    }

    @Test func pinsFollowLayersAndSkipUnconfirmed() {
        let (s, _) = snapshot()
        let today = s.pins(dayIndex: 0, layers: [.todayRoute])
        #expect(today.map(\.title) == ["A", "B"], "pending stop has no pin")
        if case .stop(_, let order, let fixed) = today[0].kind { #expect(order == 1 && fixed) }
        #expect(s.pins(dayIndex: 0, layers: [.otherDays]).map(\.title) == ["C"])
        #expect(s.pins(dayIndex: 0, layers: [.food]).map(\.title) == ["Cafe"])
        #expect(s.pins(dayIndex: 0, layers: [.saved]).map(\.title) == ["Cafe"], "unconfirmed saved never gets a pin")
        let shop = s.pins(dayIndex: 0, layers: [.shopping])
        #expect(shop.count == 1 && shop[0].dimmed, "purchased item's store is de-emphasized")
    }

    @Test func routableSavedExcludesUnconfirmed() {
        let (s, _) = snapshot()
        #expect(s.routableSaved.map(\.title) == ["Cafe"])
        #expect(s.shoppingProgress.purchased == 1)
    }
}

extension JSONDecoder {
    static var withISO: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

struct TimeZoneTests {
    let tripID = UUID()

    func day(_ order: Int, _ date: String, _ tz: String) -> TripDay {
        TripDay(id: UUID(), tripId: tripID, localDate: date, transportMode: .walking, displayOrder: order, routeRevision: 0, timeZone: tz)
    }

    @Test func todayUsesEachDaysTimeZone() {
        // 第 2 天在倫敦：UTC 2026-10-02 23:30 = 首爾 10/03 08:30、倫敦 10/03 00:30
        let timeline = [DayTimeline(day: day(0, "2026-10-02", "Asia/Seoul"), stops: []),
                        DayTimeline(day: day(1, "2026-10-03", "Europe/London"), stops: [])]
        let s = TripSnapshot(trip: Trip(id: tripID, name: "x", startDate: "2026-10-02", endDate: "2026-10-03", timeZone: "Asia/Seoul", revision: 0),
                             revision: 0, timeline: timeline, places: [:], saved: [], shopping: [])
        #expect(s.todayIndex(now: Date(timeIntervalSince1970: 1_791_027_000)) == 1)
    }

    @Test func suggestsTimeZoneFromPlaces() {
        let tokyo = Place(id: UUID(), provider: "apple_mapkit", providerPlaceId: "t", name: "東京鐵塔", nameLocal: "東京タワー", address: nil,
                          latitude: 35.66, longitude: 139.75, countryCode: "JP")
        let stop = Stop(id: UUID(), tripId: tripID, dayId: UUID(), placeId: tokyo.id, rawLabel: "東京鐵塔", resolutionStatus: .resolved,
                        startTime: nil, endTime: nil, dwellMinutes: nil, fixed: false, kind: .standard, sortOrder: 0, revision: 0)
        let seoulDay = DayTimeline(day: day(2, "2026-10-04", "Asia/Seoul"), stops: [stop])
        #expect(TripTimeZones.suggested(for: seoulDay, places: [tokyo.id: tokyo]) == "Asia/Tokyo")
        #expect(TripTimeZones.mismatch(for: seoulDay, places: [tokyo.id: tokyo]) == "Asia/Tokyo")
        let tokyoDay = DayTimeline(day: day(2, "2026-10-04", "Asia/Tokyo"), stops: [stop])
        #expect(TripTimeZones.mismatch(for: tokyoDay, places: [tokyo.id: tokyo]) == nil)
        #expect(TripTimeZones.mismatch(for: DayTimeline(day: day(0, "2026-10-01", "Asia/Seoul"), stops: []), places: [:]) == nil)
    }

    @Test func displayNames() {
        let summer = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(TripTimeZones.displayName("Asia/Tokyo", at: summer) == "東京（UTC+9）")
        #expect(TripTimeZones.displayName("Asia/Kolkata", at: summer) == "Kolkata（UTC+5:30）")
    }
}
