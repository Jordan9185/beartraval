import Foundation
import Testing
@testable import AppCore

struct ShoppingTests {
    let me = UUID(), amy = UUID()

    func entry(planned: Bool = false, date: String? = nil, events: [PurchaseEvent.Kind] = []) -> ShoppingEntry {
        let item = ShoppingItem(id: UUID(), tripId: UUID(), name: "ReFa", addedBy: me, plannedStopId: planned ? UUID() : nil)
        let ev = events.enumerated().map { PurchaseEvent(id: $0.offset, itemId: item.id, actorId: amy, type: $0.element, createdAt: Date()) }
        return ShoppingEntry(item: item, interestedUserIDs: [me], events: ev, plannedDate: date)
    }

    @Test func statusDerivesFromLatestEvent() {
        #expect(entry().status == .unscheduled)
        #expect(entry(planned: true).status == .scheduled)
        if case .purchased(let by, _) = entry(planned: true, events: [.purchased]).status { #expect(by == amy) } else { Issue.record("expected purchased") }
        #expect(entry(planned: true, events: [.purchased, .undone]).status == .scheduled, "undo restores")
        #expect(entry(events: [.purchased, .undone, .purchased]).isPurchased)
    }

    @Test func progressCountsPurchased() {
        let p = ShoppingProgress([entry(events: [.purchased]), entry(), entry(planned: true)])
        #expect(p.purchased == 1 && p.total == 3)
    }

    @Test func todayOnlyScheduledUnpurchasedForThatDay() {
        let entries = [entry(), entry(planned: true, date: "2026-10-01"), entry(planned: true, date: "2026-10-02"),
                       entry(planned: true, date: "2026-10-01", events: [.purchased])]
        #expect(TodayShopping.items(entries, on: "2026-10-01").count == 1)
    }

    @Test func purchaseProposalChangeIsPurchaseKind() {
        let ins = Insertion(index: 0, previousStopID: nil, nextStopID: nil, addedTravelMinutes: 3, addedDwellMinutes: 30, fixedCheck: .noFixedAfter, approximate: false)
        let item = UUID()
        let change = ProposalChange(insertion: ins, placeId: UUID(), label: "ReFa", shoppingItemId: item)
        #expect(change.kind == .purchase)
        #expect(change.shoppingItemId == item)
    }

    @Test func evidenceExpiry() throws {
        let json = #"{"id":"6f9619ff-8b86-d011-b42d-00c04fc964f1","item_id":"6f9619ff-8b86-d011-b42d-00c04fc964f2","place_id":"6f9619ff-8b86-d011-b42d-00c04fc964f3","evidence_type":"poi_category","evidence_url":null,"evidence_note":"x","expires_at":"2026-10-24T00:00:00Z","inventory_status":"unknown"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let m = try decoder.decode(MerchantCandidate.self, from: Data(json.utf8))
        #expect(!m.isExpired(now: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(m.isExpired(now: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func itineraryMatchesRequireSameResolvedPlaceAndFreshEvidence() throws {
        let trip = UUID(), item = UUID(), store = UUID(), otherStore = UUID()
        let day1 = UUID(), day2 = UUID(), stop1 = UUID(), stop2 = UUID(), unresolved = UUID()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
            try decoder.decode(type, from: Data(json.utf8))
        }
        let days = try [
            decode(TripDay.self, """
            {"id":"\(day1)","trip_id":"\(trip)","local_date":"2026-10-01","transport_mode":"walking","display_order":0,"route_revision":1,"time_zone":"Asia/Seoul"}
            """),
            decode(TripDay.self, """
            {"id":"\(day2)","trip_id":"\(trip)","local_date":"2026-10-02","transport_mode":"walking","display_order":1,"route_revision":1,"time_zone":"Asia/Seoul"}
            """),
        ]
        func stop(_ id: UUID, day: UUID, place: UUID?, status: String) throws -> Stop {
            try decode(Stop.self, """
            {"id":"\(id)","trip_id":"\(trip)","day_id":"\(day)","place_id":\(place.map { "\"\($0)\"" } ?? "null"),"raw_label":"店家","resolution_status":"\(status)","fixed":false,"kind":"standard","sort_order":0,"revision":1}
            """)
        }
        let stops = try [stop(stop1, day: day1, place: store, status: "resolved"),
                         stop(stop2, day: day2, place: store, status: "resolved"),
                         stop(unresolved, day: day1, place: otherStore, status: "pending_text")]
        let places = [Place(id: store, provider: "apple_mapkit", providerPlaceId: "store", name: "ReFa 明洞", nameLocal: nil,
                            address: nil, latitude: 37, longitude: 127, countryCode: "KR"),
                      Place(id: otherStore, provider: "apple_mapkit", providerPlaceId: "other", name: "別間店", nameLocal: nil,
                            address: nil, latitude: 37, longitude: 127, countryCode: "KR")]
        func candidate(_ place: UUID, expires: String) throws -> MerchantCandidate {
            try decode(MerchantCandidate.self, """
            {"id":"\(UUID())","item_id":"\(item)","place_id":"\(place)","evidence_type":"official_locator","evidence_url":"https://example.com/stores","evidence_note":null,"expires_at":"\(expires)","inventory_status":"unknown"}
            """)
        }
        let fresh = try candidate(store, expires: "2026-11-01T00:00:00Z")
        let stale = try candidate(otherStore, expires: "2026-09-01T00:00:00Z")
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        let shoppingItem = ShoppingItem(id: item, tripId: trip, name: "ReFa CARAT", addedBy: me)
        let found = ShoppingItineraryMatch.find(items: [shoppingItem], stops: stops, days: days, places: places,
                                                candidates: [fresh, stale], now: now)
        #expect(found[item]?.map(\.dayNumber) == [1, 2])
        #expect(found[item]?.allSatisfy { $0.placeName.contains("ReFa") } == true)
        #expect(found[item]?.contains { $0.stopID == unresolved } == false)
    }

    @Test func matchingStoreNameIsOnlyAnUnverifiedSuggestion() throws {
        let trip = UUID(), day = UUID(), placeID = UUID(), itemID = UUID()
        let decoder = JSONDecoder()
        let tripDay = try decoder.decode(TripDay.self, from: Data("""
        {"id":"\(day)","trip_id":"\(trip)","local_date":"2026-10-01","transport_mode":"walking","display_order":0,"route_revision":1,"time_zone":"Asia/Seoul"}
        """.utf8))
        let stop = try decoder.decode(Stop.self, from: Data("""
        {"id":"\(UUID())","trip_id":"\(trip)","day_id":"\(day)","place_id":"\(placeID)","raw_label":"ReFa 店","resolution_status":"resolved","fixed":false,"kind":"standard","sort_order":0,"revision":1}
        """.utf8))
        let place = Place(id: placeID, provider: "apple_mapkit", providerPlaceId: "refa", name: "ReFa 聖水", nameLocal: nil,
                          address: nil, latitude: 37, longitude: 127, countryCode: "KR")
        let item = ShoppingItem(id: itemID, tripId: trip, name: "ReFa 蓮蓬頭", addedBy: me)
        let found = ShoppingItineraryMatch.find(items: [item], stops: [stop], days: [tripDay], places: [place], candidates: [])
        #expect(found[itemID]?.first?.evidenceType == nil)
        #expect(found[itemID]?.first?.placeName.contains("ReFa") == true)
        let unrelated = ShoppingItem(id: UUID(), tripId: trip, name: "護手霜", addedBy: me)
        #expect(ShoppingItineraryMatch.find(items: [unrelated], stops: [stop], days: [tripDay], places: [place], candidates: []).isEmpty)
    }

    @Test func sharedProductStoreHintMatchesAnItineraryStopWithoutClaimingStock() throws {
        let trip = UUID(), day = UUID(), placeID = UUID(), itemID = UUID()
        let decoder = JSONDecoder()
        let tripDay = try decoder.decode(TripDay.self, from: Data("""
        {"id":"\(day)","trip_id":"\(trip)","local_date":"2026-10-01","transport_mode":"walking","display_order":0,"route_revision":1,"time_zone":"Asia/Seoul"}
        """.utf8))
        let stop = try decoder.decode(Stop.self, from: Data("""
        {"id":"\(UUID())","trip_id":"\(trip)","day_id":"\(day)","place_id":"\(placeID)","raw_label":"眼鏡店","resolution_status":"resolved","fixed":false,"kind":"standard","sort_order":0,"revision":1}
        """.utf8))
        let place = Place(id: placeID, provider: "apple_mapkit", providerPlaceId: "ivyn", name: "IVYNYU LAB 聖水",
                          nameLocal: nil, address: nil, latitude: 37, longitude: 127, countryCode: "KR")
        let item = ShoppingItem(id: itemID, tripId: trip, name: "墨鏡", addedBy: me,
                                storeHint: "IVYNYU LAB", storeEvidence: "image:1")
        let found = ShoppingItineraryMatch.find(items: [item], stops: [stop], days: [tripDay], places: [place], candidates: [])
        #expect(found[itemID]?.first?.evidenceType == nil)
        #expect(found[itemID]?.first?.evidenceNote?.contains("IVYNYU LAB") == true)
    }

    @Test func shortBrandMatchesWholeStoreNameOnly() throws {
        let trip = UUID(), day = UUID(), loeID = UUID(), chloeID = UUID(), itemID = UUID()
        let decoder = JSONDecoder()
        let tripDay = try decoder.decode(TripDay.self, from: Data("""
        {"id":"\(day)","trip_id":"\(trip)","local_date":"2026-10-01","transport_mode":"walking","display_order":0,"route_revision":1,"time_zone":"Asia/Seoul"}
        """.utf8))
        func stop(_ placeID: UUID) throws -> Stop {
            try decoder.decode(Stop.self, from: Data("""
            {"id":"\(UUID())","trip_id":"\(trip)","day_id":"\(day)","place_id":"\(placeID)","raw_label":"香水店","resolution_status":"resolved","fixed":false,"kind":"standard","sort_order":0,"revision":1}
            """.utf8))
        }
        let places = [Place(id: loeID, provider: "apple_mapkit", providerPlaceId: "loe", name: "LOE 聖水",
                            nameLocal: nil, address: nil, latitude: 37, longitude: 127, countryCode: "KR"),
                      Place(id: chloeID, provider: "apple_mapkit", providerPlaceId: "chloe", name: "Chloe 聖水",
                            nameLocal: nil, address: nil, latitude: 37, longitude: 127, countryCode: "KR")]
        let item = ShoppingItem(id: itemID, tripId: trip, name: "LOE 香水", addedBy: me)
        let found = ShoppingItineraryMatch.find(items: [item], stops: [try stop(loeID), try stop(chloeID)],
                                                days: [tripDay], places: places, candidates: [])
        #expect(found[itemID]?.count == 1)
        #expect(found[itemID]?.first?.placeName.contains("LOE 聖水") == true)
    }
}
