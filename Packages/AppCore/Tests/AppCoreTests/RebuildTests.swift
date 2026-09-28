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
