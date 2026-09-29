import Foundation
import Testing
@testable import AppCore

@Suite struct RebuildTests {
    @Test func packingChangesRequireCheckingNewQuantity() {
        var old = PackingItem(tripID: UUID(), ownerID: UUID())
        old.name = "雨傘"; old.packed = true
        var next = old
        next.quantity = 2
        #expect(next.needsRepacking(comparedTo: old))
        next = old; next.note = "放外袋"
        #expect(!next.needsRepacking(comparedTo: old))
        next.carrier_id = UUID()
        #expect(next.needsRepacking(comparedTo: old))
    }
    @Test func taxiLanguageSwitchKeepsDestination() {
        var card = TaxiCard(unlocatedName: "原始店名", countryCode: "CN", addressHint: "上海市地址線索")
        #expect(card.language == .simplifiedChinese)
        let address = card.address
        card.useLanguage(.korean)
        #expect(card.name == "原始店名")
        #expect(card.address == address)
        #expect(card.request.contains("감사"))
    }
    @Test func apiFailureNeverSaysNoCharge() {
        #expect(PersonalAI.waitingMessage("claude_api_error")?.contains("可能已產生用量") == true)
        #expect(PersonalAI.waitingMessage("claude_api_not_configured")?.contains("未切換到其他模式") == true)
    }
}

@Suite struct RebuildOfflineTests {
    @Test func purchaseIntentSurvivesRestartAndCannotBeReplacedInFlight() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), stranger = UUID(), trip = UUID()
        let item = ShoppingItem(id: UUID(), tripId: trip, name: "藥妝", addedBy: owner)
        let draft = PurchaseJournal.SharedDraft(item: item, desired: 4, bought: 2, buyer: owner, demands: [], members: [])
        let first = PurchaseJournal(directory: root)
        try await first.cache(draft, owner: owner)
        try await first.enqueue(draft, owner: owner)
        let reopened = PurchaseJournal(directory: root)
        #expect(await reopened.sharedDraft(id: item.id, owner: owner)?.bought == 2)
        #expect(await reopened.hasPending(id: item.id, owner: owner))
        #expect(await reopened.sharedDraft(id: item.id, owner: stranger) == nil)
        await #expect(throws: BackendError.staleRevision) { try await reopened.enqueue(draft, owner: owner) }
        try await reopened.discard(id: item.id, owner: owner)
        #expect(await reopened.hasPending(id: item.id, owner: owner) == false)
    }
    @Test func shoppingListOverlaysOnlyOwnPendingQuantities() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), trip = UUID()
        let item = ShoppingItem(id: UUID(), tripId: trip, name: "伴手禮", addedBy: owner)
        let journal = PurchaseJournal(directory: root)
        try await journal.cache(entries: [ShoppingEntry(item: item, interestedUserIDs: [], events: [])], tripID: trip, owner: owner)
        try await journal.enqueue(PurchaseJournal.SharedDraft(item: item, desired: 4, bought: 2, buyer: owner, demands: [], members: []), owner: owner)
        let reopened = PurchaseJournal(directory: root)
        let entries = await reopened.shoppingEntries(tripID: trip, owner: owner)
        #expect(entries.first?.item.boughtQuantity == 2)
        #expect(entries.first?.events.isEmpty == true)
        #expect(await reopened.shoppingEntries(tripID: trip, owner: UUID()).isEmpty)
        #expect(await reopened.shoppingEntries(tripID: UUID(), owner: owner).isEmpty)
        #expect(await reopened.pendingShoppingIDs(tripID: trip, owner: owner) == [item.id])
        try await reopened.discard(id: item.id, owner: owner)
        #expect(await reopened.shoppingEntries(tripID: trip, owner: owner).first?.item.boughtQuantity == item.boughtQuantity)
    }
    @Test func archivedCatalogIsAccountScopedAndDeletionDoesNotReappearOffline() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let trip = Trip(id: UUID(), name: "舊旅程", startDate: "2026-01-01", endDate: "2026-01-02", timeZone: "Asia/Taipei", revision: 1)
        let cache = TripCatalogCache(directory: root, owner: owner)
        try cache.save(.init(trips: [trip], archivedIDs: [trip.id]))
        #expect(TripCatalogCache(directory: root, owner: owner).load()?.archivedIDs == [trip.id])
        #expect(TripCatalogCache(directory: root, owner: UUID()).load() == nil)
        cache.removeTrip(trip.id)
        #expect(cache.load()?.trips.isEmpty == true)
        #expect(cache.load()?.archivedIDs.isEmpty == true)
    }
    @Test func packingPrivateIntentSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), trip = UUID()
        var item = PackingItem(tripID: trip, ownerID: owner); item.name = "充電器"; item.quantity = 2
        let first = PackingJournal(directory: root)
        try await first.enqueue(item, deleted: false, owner: owner)
        let reopened = PackingJournal(directory: root)
        #expect(await reopened.items(tripID: trip, owner: owner).first?.quantity == 2)
        #expect(await reopened.items(tripID: trip, owner: UUID()).isEmpty)
    }
}

@Suite struct ShoppingSwapTests {
    @Test func swapActionCarriesOriginalStopAndVerifiedCandidate() throws {
        let item = UUID(), stop = UUID(), fromDay = UUID(), toDay = UUID()
        let candidate = ShoppingStoreSuggestion(name: "中文譯名", koreanName: "원문점", addressLocal: "當地地址",
                                                searchQuery: "원문점", reason: "來源", sourceURL: "https://example.test/b")
        let action = ArrangementAction.shoppingSwap(itemID: item, fromStopID: stop, fromDayID: fromDay, toDayID: toDay,
                                                    candidateIndex: 1, candidate: candidate, removeEmptySource: false)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? [String: Any])
        #expect(json["kind"] as? String == "shopping_swap")
        #expect(json["source_stop_id"] as? String == stop.uuidString)
        #expect(json["source_day_id"] as? String == fromDay.uuidString)
        #expect(json["day_id"] as? String == toDay.uuidString)
        // 後端以原文店名核對候選，譯名不會被當成另一間分店。
        #expect(json["store_name"] as? String == candidate.displayName)
        #expect(json["address_local"] as? String == "當地地址")
        #expect(json["remove_empty_source"] as? Bool == false)
    }

    @Test func previewDecodesSwappedOrigin() throws {
        let stop = UUID(), day = UUID(), old = UUID()
        let data = Data("""
        {"before":[],"after":[],"outcomes":[{"status":"scheduled","stop_id":"\(stop)","day_id":"\(day)",
        "swapped_from":{"stop_id":"\(old)","day_id":"\(day)","removed":true}}]}
        """.utf8)
        let preview = try JSONDecoder().decode(ArrangementPreview.self, from: data)
        #expect(preview.outcomes?.first?.swapped_from?.stop_id == old)
        #expect(preview.outcomes?.first?.swapped_from?.removed == true)
    }
}

@Suite struct PrivateHistoryTests {
    @Test func decodesSnapshotAndDescribesReason() throws {
        let data = Data("""
        [{"id":"\(UUID())","trip_name":"首爾","start_date":"2026-10-01","end_date":"2026-10-03","reason":"trip_deleted",
          "packing":[{"name":"雨傘","quantity":2,"note":null,"packed":true}],
          "purchases":[{"name":"雨傘","desired_quantity":2,"bought_quantity":1,"purchase_timing":"before_trip"}],
          "created_at":"2026-09-29T00:00:00Z"}]
        """.utf8)
        let records = try JSONDecoder().decode([PrivateTripHistory].self, from: data)
        #expect(records.first?.reasonText == "旅程已刪除")
        #expect(records.first?.packing.first?.packed == true)
        #expect(records.first?.purchases.first?.bought_quantity == 1)
    }
}
