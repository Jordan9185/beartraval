import Foundation
import Supabase
import Testing
@testable import AppCore

/// 對本機 Supabase 跑 RPC 整合測試（WP2 完成證據）。
///
///     supabase start
///     BEARTRAVEL_TEST_SUPABASE_URL=http://127.0.0.1:54321 \
///     BEARTRAVEL_TEST_SUPABASE_ANON_KEY=<supabase status 的 anon key> swift test
///
/// 沒設定環境變數時略過。每次以隨機 Email 註冊兩個測試使用者。
@Suite(.enabled(if: IntegrationEnv.config != nil))
struct ItineraryIntegrationTests {
    @Test func commitReadBackStaleAndPermission() async throws {
        let owner = try await IntegrationEnv.signedInRepository()
        let trip = try await owner.createTrip(name: "WP2 integration", startDate: "2026-10-01", endDate: "2026-10-02", timeZone: "Asia/Seoul")
        let days = try await owner.days(of: trip.id)
        #expect(days.count == 2)
        let day = try #require(days.first)
        #expect(day.routeRevision == 0)

        let market = try await owner.upsertPlace(PlaceDraft(
            providerPlaceId: "it-\(UUID().uuidString)", name: "Gwangjang Market", nameLocal: "광장시장",
            latitude: 37.5700, longitude: 126.9996, countryCode: "kr"))
        #expect(market.countryCode == "KR")

        let revision = try await owner.commitItinerary(dayID: day.id, expectedRouteRevision: 0, stops: [
            StopDraft(placeId: market.id, rawLabel: "광장시장", startTime: "10:30", fixed: true),
            StopDraft(rawLabel: "카페 (지점 미정)"),
        ])
        #expect(revision == 1)

        let stops = try await owner.stops(of: trip.id)
        #expect(stops.map(\.rawLabel) == ["광장시장", "카페 (지점 미정)"])
        #expect(stops[0].isRoutable && stops[0].fixed && stops[0].startTime == "10:30:00")
        #expect(stops[1].resolutionStatus == .pendingText && !stops[1].isRoutable)
        #expect(try await owner.places(ids: [market.id]).first?.nameLocal == "광장시장")

        // 過期 revision：被拒且不寫入。
        await #expect(throws: BackendError.staleRevision) {
            try await owner.commitItinerary(dayID: day.id, expectedRouteRevision: 0, stops: [StopDraft(rawLabel: "overwrite")])
        }
        #expect(try await owner.stops(of: trip.id).count == 2)

        // 以目前 revision 重新提交：保留 id 更新、未列出的軟刪除。
        let kept = StopDraft(stops[0])
        #expect(try await owner.commitItinerary(dayID: day.id, expectedRouteRevision: 1, stops: [kept]) == 2)
        let after = try await owner.stops(of: trip.id)
        #expect(after.map(\.id) == [stops[0].id])

        // 非成員：看不到 Trip，也不能寫入。
        let outsider = try await IntegrationEnv.signedInRepository()
        #expect(try await outsider.myTrips().contains { $0.id == trip.id } == false)
        #expect(try await outsider.stops(of: trip.id).isEmpty)
        await #expect(throws: BackendError.forbidden) {
            try await outsider.commitItinerary(dayID: day.id, expectedRouteRevision: 2, stops: [])
        }
    }
}

enum IntegrationEnv {
    static let config: BackendConfig? = {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["BEARTRAVEL_TEST_SUPABASE_URL"].flatMap(URL.init(string:)),
              let key = env["BEARTRAVEL_TEST_SUPABASE_ANON_KEY"], !key.isEmpty else { return nil }
        return BackendConfig(url: url, anonKey: key)
    }()

    static func signedInRepository() async throws -> TripRepository {
        let client = Backend.makeClient(config!, storage: MemoryStorage())
        _ = try await client.auth.signUp(email: "it-\(UUID().uuidString.prefix(8).lowercased())@example.com",
                                         password: UUID().uuidString)
        return TripRepository(client: client)
    }
}

final class MemoryStorage: AuthLocalStorage, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

@Suite(.enabled(if: IntegrationEnv.config != nil))
struct ImportIntegrationTests {
    @Test func importKeepsTextThroughFailedParseAndCommits() async throws {
        let client = Backend.makeClient(IntegrationEnv.config!, storage: MemoryStorage())
        _ = try await client.auth.signUp(email: "it-\(UUID().uuidString.prefix(8).lowercased())@example.com", password: UUID().uuidString)
        let service = SupabaseImportService(client: client)
        let text = "Day 1 10:00 광장시장\nXXX Shoes"

        let created = try await service.createImport(tripName: "Import IT", startDate: "2026-10-01", endDate: "2026-10-02",
                                                     timeZone: "Asia/Seoul", rawText: text)
        #expect(created.parseStatus == .pending)

        // 本機沒有 ANTHROPIC_API_KEY：解析失敗，但原文還在。有 key 時則應解析成功。
        let parsed = try await service.parse(importID: created.id)
        if parsed.parseStatus == .failed {
            #expect(parsed.parseError == "missing_api_key")
        } else {
            #expect(parsed.parseStatus == .parsed)
            #expect(parsed.parseResult?.draft.days.isEmpty == false)
        }
        #expect(parsed.rawText == text)

        let edited = try await service.updateText(importID: created.id, rawText: text + "\nDay 2 N서울타워")
        #expect(edited.parseStatus == .pending)
        #expect(edited.rawText.hasSuffix("N서울타워"))

        let place = try await service.registerPlace(PlaceDraft(providerPlaceId: "it-\(UUID().uuidString)", name: "Gwangjang Market",
                                                               latitude: 37.57, longitude: 126.9996, countryCode: "KR"))
        let trip = try await service.commit(importID: created.id, days: [
            ImportDayCommit(date: "2026-10-01", stops: [
                StopDraft(placeId: place.id, rawLabel: "광장시장", startTime: "10:00"),
                StopDraft(rawLabel: "XXX Shoes"),
            ]),
        ])
        let stops = try await TripRepository(client: client).stops(of: trip.id)
        #expect(stops.map(\.resolutionStatus) == [.resolved, .pendingText])

        await #expect(throws: BackendError.self) {
            _ = try await service.commit(importID: created.id, days: [])
        }
    }
}

/// WP5 完成證據：兩個客戶端同日修改，第二個收到 STALE 並重新確認（AC-13）。
@Suite(.enabled(if: IntegrationEnv.config != nil))
struct ProposalIntegrationTests {
    @Test func twoEditorsSecondGetsStaleAndReconfirms() async throws {
        let ownerClient = Backend.makeClient(IntegrationEnv.config!, storage: MemoryStorage())
        _ = try await ownerClient.auth.signUp(email: "it-\(UUID().uuidString.prefix(8).lowercased())@example.com", password: UUID().uuidString)
        let editorClient = Backend.makeClient(IntegrationEnv.config!, storage: MemoryStorage())
        _ = try await editorClient.auth.signUp(email: "it-\(UUID().uuidString.prefix(8).lowercased())@example.com", password: UUID().uuidString)
        let owner = TripRepository(client: ownerClient), editor = TripRepository(client: editorClient)

        // Owner 建 Trip 與兩個已確認地點，邀請 Editor。
        let trip = try await owner.createTrip(name: "Race", startDate: "2026-10-01", endDate: "2026-10-01", timeZone: "Asia/Tokyo")
        let day = try #require(try await owner.days(of: trip.id).first)
        func place(_ name: String, _ lat: Double) async throws -> Place {
            try await owner.upsertPlace(PlaceDraft(providerPlaceId: "it-\(UUID().uuidString)", name: name, latitude: lat, longitude: 132.4, countryCode: "JP"))
        }
        let pa = try await place("A", 34.01), pb = try await place("B", 34.02), px = try await place("X", 34.09), py = try await place("Y", 34.08)
        _ = try await owner.commitItinerary(dayID: day.id, expectedRouteRevision: 0, stops: [
            StopDraft(placeId: pa.id, rawLabel: "A"), StopDraft(placeId: pb.id, rawLabel: "B"),
        ])
        struct InviteParams: Encodable { let p_trip_id: UUID, p_role: String }
        struct AcceptParams: Encodable { let p_token: String }
        let token: String = try await ownerClient.rpc("create_invite", params: InviteParams(p_trip_id: trip.id, p_role: "editor")).execute().value
        try await editorClient.rpc("accept_invite", params: AcceptParams(p_token: token)).execute()

        // 路線時間用假供應商；這裡驗證的是後端的 revision 行為。
        func coord(_ p: Place) -> RoutePoint { RoutePoint(coordinate: Coordinate(latitude: p.latitude, longitude: p.longitude), countryCode: "JP") }
        var table: [(RoutePoint, RoutePoint, Double)] = []
        for (p, q) in [(pa, pb), (pa, px), (px, pb), (pb, px), (px, pa), (pa, py), (py, pb), (pb, py), (py, pa), (py, px), (px, py)] {
            table.append((coord(p), coord(q), 5))
        }
        let matcher = RouteMatcher(provider: FakeProvider(legs(table)))
        let ownerFlow = AddToDayFlow(service: owner, matcher: matcher)
        let editorFlow = AddToDayFlow(service: editor, matcher: matcher)

        // 兩人都看到 revision 1 的試算結果。
        let (ownerPending, _) = try await ownerFlow.propose(placeID: px.id, label: "X", point: coord(px), dwellMinutes: 30,
                                                            tripID: trip.id, dayID: day.id, mode: .walking)
        let (editorPending, _) = try await editorFlow.propose(placeID: py.id, label: "Y", point: coord(py), dwellMinutes: 30,
                                                              tripID: trip.id, dayID: day.id, mode: .walking)
        #expect(ownerPending?.proposal.expectedRouteRevision == 1)
        #expect(editorPending?.proposal.expectedRouteRevision == 1)

        // Owner 先確認；Editor 確認時收到過期，拿到重新計算的 proposal。
        guard case .added = try await ownerFlow.confirm(ownerPending!, point: coord(px)) else { Issue.record("owner should add"); return }
        let editorResult = try await editorFlow.confirm(editorPending!, point: coord(py))
        guard case .needsReconfirm(let fresh) = editorResult else { Issue.record("expected reconfirm, got \(editorResult)"); return }
        #expect(fresh.proposal.expectedRouteRevision == 2)
        #expect(try await owner.stops(of: trip.id).map(\.rawLabel).contains("Y") == false, "stale confirm wrote nothing")

        let staleRow: [ChangeProposal] = try await editorClient.from("change_proposals").select().eq("id", value: editorPending!.proposal.id).execute().value
        #expect(staleRow.first?.status == .stale)

        // Editor 看過新數字後再確認。
        guard case .added = try await editorFlow.confirm(fresh, point: coord(py)) else { Issue.record("editor should add"); return }
        let labels = try await owner.stops(of: trip.id).map(\.rawLabel)
        #expect(Set(labels) == ["A", "B", "X", "Y"])
    }
}

/// AC-07：Amy 新增地點進共同 Saved，正式行程不變；重複分享去重。
@Suite(.enabled(if: IntegrationEnv.config != nil))
struct SavedIntegrationTests {
    @Test func friendSaveGoesToSharedSavedAndReshareDedupes() async throws {
        let ownerClient = Backend.makeClient(IntegrationEnv.config!, storage: MemoryStorage())
        _ = try await ownerClient.auth.signUp(email: "it-\(UUID().uuidString.prefix(8).lowercased())@example.com", password: UUID().uuidString)
        let amyClient = Backend.makeClient(IntegrationEnv.config!, storage: MemoryStorage())
        _ = try await amyClient.auth.signUp(email: "it-\(UUID().uuidString.prefix(8).lowercased())@example.com", password: UUID().uuidString)
        let owner = TripRepository(client: ownerClient), amy = TripRepository(client: amyClient)

        let trip = try await owner.createTrip(name: "Saved IT", startDate: "2026-10-01", endDate: "2026-10-01", timeZone: "Asia/Seoul")
        struct InviteParams: Encodable { let p_trip_id: UUID, p_role: String }
        struct AcceptParams: Encodable { let p_token: String }
        let token: String = try await ownerClient.rpc("create_invite", params: InviteParams(p_trip_id: trip.id, p_role: "editor")).execute().value
        try await amyClient.rpc("accept_invite", params: AcceptParams(p_token: token)).execute()

        let url = URL(string: "https://www.threads.net/@cafe/post/ABC?igsh=1")!
        let source = SavedSource(url: url.absoluteString, canonicalUrl: "https://threads.com/@cafe/post/ABC", summary: "성수 카페")
        let place = try await amy.upsertPlace(PlaceDraft(providerPlaceId: "it-\(UUID().uuidString)", name: "Onion", latitude: 37.5447, longitude: 127.0584, countryCode: "KR"))
        let (saved, dup1) = try await amy.savePlace(tripID: trip.id, label: "Onion", category: .cafe, placeID: place.id, source: source)
        #expect(!dup1)

        // Owner 從另一個網址變體再分享同一篇。
        let (again, dup2) = try await owner.savePlace(tripID: trip.id, label: "Onion", category: .cafe, placeID: nil,
                                                      source: SavedSource(url: "https://threads.com/@cafe/post/ABC", canonicalUrl: "https://threads.com/@cafe/post/ABC", summary: nil))
        #expect(dup2)
        #expect(again.id == saved.id)

        let entries = try await owner.savedEntries(of: trip.id)
        #expect(entries.count == 1)
        #expect(entries[0].interestedUserIDs.count == 2)
        #expect(entries[0].source?.canonicalUrl == "https://threads.com/@cafe/post/ABC")
        #expect(entries[0].place?.name == "Onion")
        #expect(try await owner.stops(of: trip.id).isEmpty, "saving never changes the itinerary")

        // 未確認地點也能先收藏。
        let (pending, _) = try await amy.savePlace(tripID: trip.id, label: "IG 貼文的店", category: .eat, placeID: nil,
                                                    source: SavedSource(url: "https://instagram.com/p/X", canonicalUrl: "https://instagram.com/p/X", summary: nil))
        #expect(pending.placeId == nil)
        #expect(try await owner.savedEntries(of: trip.id).count == 2)
    }
}

/// WP7：兩個客戶端同步（Realtime 推送 + 重新連線補拉），以及直接呼叫 API 越權被拒（AC-12）。
@Suite(.enabled(if: IntegrationEnv.config != nil), .serialized)
struct SyncIntegrationTests {
    func signedIn() async throws -> (TripRepository, SupabaseClient) {
        let client = Backend.makeClient(IntegrationEnv.config!, storage: MemoryStorage())
        _ = try await client.auth.signUp(email: "it-\(UUID().uuidString.prefix(8).lowercased())@example.com", password: UUID().uuidString)
        return (TripRepository(client: client), client)
    }

    @MainActor
    @Test func realtimePushAndCatchUp() async throws {
        let (owner, _) = try await signedIn()
        let (editor, _) = try await signedIn()
        let (viewer, _) = try await signedIn()
        let trip = try await owner.createTrip(name: "Sync", startDate: "2026-10-01", endDate: "2026-10-01", timeZone: "Asia/Seoul")
        _ = try await editor.acceptInvite(token: try await owner.createInvite(tripID: trip.id, role: .editor))
        _ = try await viewer.acceptInvite(token: try await owner.createInvite(tripID: trip.id, role: .viewer))
        #expect(try await viewer.myRole(in: trip.id) == .viewer)
        #expect(try await owner.members(of: trip.id).count == 3)

        // Owner 的裝置訂閱變更。
        let start = try await owner.tripRevision(trip.id)
        var received: [TripEvent] = []
        let sync = TripSync(tripID: trip.id, repository: owner, revision: start) { received.append(contentsOf: $0) }
        await sync.start()
        try await Task.sleep(for: .seconds(1))

        // Editor 新增 Saved → Owner 收到通知（AC-07）。
        let (saved, _) = try await editor.savePlace(tripID: trip.id, label: "Amy 的餐廳", category: .eat, placeID: nil, source: nil)
        for _ in 0..<50 where !received.contains(where: { $0.kind == "saved.changed" }) {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(received.contains { $0.kind == "saved.changed" && $0.entityId == saved.id }, "owner device notified")
        #expect(try await owner.stops(of: trip.id).isEmpty, "friend's addition does not touch the itinerary")
        await sync.stop()

        // 另一台停在舊 revision 的裝置：重新連線時補拉。
        var caughtUp: [TripEvent] = []
        let stale = TripSync(tripID: trip.id, repository: owner, revision: start) { caughtUp.append(contentsOf: $0) }
        await stale.catchUp()
        #expect(caughtUp.contains { $0.kind == "saved.changed" })
        #expect(stale.revision == (try await owner.tripRevision(trip.id)))

        // AC-12：Viewer 直接呼叫 API 寫入全部被拒。
        await #expect(throws: BackendError.forbidden) {
            _ = try await viewer.savePlace(tripID: trip.id, label: "x", category: .eat, placeID: nil, source: nil)
        }
        await #expect(throws: BackendError.forbidden) { try await viewer.setInterest(savedID: saved.id, interested: true) }
        await #expect(throws: BackendError.forbidden) {
            _ = try await viewer.createInvite(tripID: trip.id, role: .viewer)
        }
        await #expect(throws: BackendError.forbidden) {
            _ = try await editor.createInvite(tripID: trip.id, role: .viewer)
        }
    }
}

/// WP8：選店經 proposal 建 Purchase Stop；旅伴購買同步到另一台（AC-10、AC-11）。
@Suite(.enabled(if: IntegrationEnv.config != nil))
struct ShoppingIntegrationTests {
    @MainActor
    @Test func purchaseStopAndSyncedPurchase() async throws {
        func signedIn() async throws -> TripRepository {
            let client = Backend.makeClient(IntegrationEnv.config!, storage: MemoryStorage())
            _ = try await client.auth.signUp(email: "it-\(UUID().uuidString.prefix(8).lowercased())@example.com", password: UUID().uuidString)
            return TripRepository(client: client)
        }
        let owner = try await signedIn(), amy = try await signedIn()
        let trip = try await owner.createTrip(name: "Shop", startDate: "2026-10-01", endDate: "2026-10-01", timeZone: "Asia/Tokyo")
        _ = try await amy.acceptInvite(token: try await owner.createInvite(tripID: trip.id, role: .editor))
        let day = try #require(try await owner.days(of: trip.id).first)

        let item = try await amy.addShoppingItem(tripID: trip.id, name: "ReFa", note: nil, url: nil, clientOpID: UUID())
        #expect(try await owner.shoppingEntries(of: trip.id).first?.status == .unscheduled, "AC-09")

        // 選店 → proposal → 確認 → Purchase Stop。
        let store = try await owner.upsertPlace(PlaceDraft(providerPlaceId: "it-\(UUID().uuidString)", name: "Fukuya", latitude: 34.39, longitude: 132.46, countryCode: "JP"))
        try await owner.addMerchant(itemID: item.id, placeID: store.id, evidence: .poiCategory, url: nil, note: "search")
        let point = RoutePoint(coordinate: Coordinate(latitude: 34.39, longitude: 132.46), countryCode: "JP")
        let flow = AddToDayFlow(service: owner, matcher: RouteMatcher(provider: FakeProvider([:])))
        let (pending, _) = try await flow.propose(placeID: store.id, label: "ReFa @ Fukuya", point: point, dwellMinutes: 30,
                                                  tripID: trip.id, dayID: day.id, mode: .walking, shoppingItemID: item.id)
        guard case .added = try await flow.confirm(try #require(pending), point: point) else { Issue.record("not added"); return }
        let entry = try #require(try await owner.shoppingEntries(of: trip.id).first)
        #expect(entry.status == .scheduled)
        #expect(entry.plannedDate == "2026-10-01")
        #expect(try await owner.stops(of: trip.id).first?.kind == .purchase)
        #expect(try await owner.merchants(of: item.id).first?.inventoryStatus == "unknown")

        // Owner 裝置訂閱；Amy 標記已購買 → Owner 收到並看到已購買。
        var events: [TripEvent] = []
        let sync = TripSync(tripID: trip.id, repository: owner, revision: try await owner.tripRevision(trip.id)) { events += $0 }
        await sync.start()
        try await Task.sleep(for: .seconds(1))
        try await amy.recordPurchase(itemID: item.id, purchased: true, clientOpID: UUID())
        for _ in 0..<50 where !events.contains(where: { $0.kind == "shopping.changed" }) { try await Task.sleep(for: .milliseconds(200)) }
        await sync.stop()
        #expect(events.contains { $0.kind == "shopping.changed" })
        #expect(try await owner.shoppingEntries(of: trip.id).first?.isPurchased == true)
        #expect(TodayShopping.items(try await owner.shoppingEntries(of: trip.id), on: "2026-10-01").isEmpty, "purchased leaves today's list")

        // Owner 可撤銷旅伴的誤勾。
        try await owner.recordPurchase(itemID: item.id, purchased: false, clientOpID: nil)
        #expect(try await amy.shoppingEntries(of: trip.id).first?.status == .scheduled)
    }
}

/// WP9：Today／Map 共用的 snapshot 與伺服器 revision 一致（AC-02）。
@Suite(.enabled(if: IntegrationEnv.config != nil))
struct SnapshotIntegrationTests {
    @Test func snapshotMatchesServerRevision() async throws {
        let client = Backend.makeClient(IntegrationEnv.config!, storage: MemoryStorage())
        _ = try await client.auth.signUp(email: "it-\(UUID().uuidString.prefix(8).lowercased())@example.com", password: UUID().uuidString)
        let repo = TripRepository(client: client)
        let trip = try await repo.createTrip(name: "Snap", startDate: "2026-10-01", endDate: "2026-10-02", timeZone: "Asia/Seoul")
        let place = try await repo.upsertPlace(PlaceDraft(providerPlaceId: "it-\(UUID().uuidString)", name: "A", latitude: 37.5, longitude: 127, countryCode: "KR"))
        let day = try #require(try await repo.days(of: trip.id).first)
        _ = try await repo.commitItinerary(dayID: day.id, expectedRouteRevision: 0, stops: [StopDraft(placeId: place.id, rawLabel: "A", fixed: true)])
        _ = try await repo.savePlace(tripID: trip.id, label: "Cafe", category: .cafe, placeID: nil, source: nil)
        _ = try await repo.addShoppingItem(tripID: trip.id, name: "ReFa", note: nil, url: nil, clientOpID: nil)

        let snap = try await repo.snapshot(of: trip)
        #expect(snap.revision == (try await repo.tripRevision(trip.id)))
        #expect(snap.timeline.count == 2)
        #expect(snap.pins(dayIndex: 0, layers: [.todayRoute]).count == 1)
        #expect(snap.saved.count == 1 && snap.shopping.count == 1)

        _ = try await repo.addShoppingItem(tripID: trip.id, name: "Momiji", note: nil, url: nil, clientOpID: nil)
        let next = try await repo.snapshot(of: trip)
        #expect(next.revision > snap.revision)
        #expect(next.shopping.count == 2)
    }
}
