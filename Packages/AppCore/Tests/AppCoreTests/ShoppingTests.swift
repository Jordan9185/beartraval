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
}
