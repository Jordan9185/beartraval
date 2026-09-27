#if DEBUG
import AppCore
import Foundation
import ShareCore
import Supabase
#if canImport(UIKit)
import UIKit
#endif
import SwiftUI

/// XCUITest 用的匯入情境（不需登入、不連後端）。App 以 `-UITestImport <scenario>` 啟動時使用。
///
/// - `ambiguous`：含兩個可能分店的「XXX Shoes」（AC-01）
/// - `failThenSucceed`：第一次解析失敗，重試後成功（原文不丟）
public struct ImportUITestRoot: View {
    let scenario: String
    @State private var created: Trip?

    public init(scenario: String) {
        self.scenario = scenario
    }

    public var body: some View {
        NavigationStack {
            if ["savedButtons", "personalButtons", "removeFailure", "savedViewer", "confirmMultiple", "confirmFailure"].contains(scenario) {
                SavedButtonsUITestScene(personal: scenario == "personalButtons" || scenario.hasPrefix("confirm"), failFirst: scenario == "removeFailure", viewer: scenario == "savedViewer", multiple: scenario == "confirmMultiple", confirmFails: scenario == "confirmFailure")
            } else if scenario == "startup" || scenario == "startupRetry" {
                StartupUITestScene(failFirst: scenario == "startupRetry")
            } else if scenario == "sourceImage" {
                Form {
                    Section("原始內容") { SourceImagePreview(data: Self.sourceImageData) }
                }
            } else if let created {
                ContentUnavailableView("已建立 \(created.name)", systemImage: "checkmark.circle")
                    .accessibilityIdentifier("tripCreated")
            } else {
                ImportFlowView(session: FakeImportService.session, service: FakeImportService(failFirst: scenario == "failThenSucceed"),
                               placeSearch: FakePlaceSearch()) { created = $0 }
            }
        }
    }
    private static var sourceImageData: Data {
        #if canImport(UIKit)
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 1600)).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 1600))
            for line in 0..<30 {
                ("來源文字第 \(line + 1) 列" as NSString).draw(at: CGPoint(x: 12, y: 12 + line * 50),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
            }
        }
        #else
        return Data()
        #endif
    }

}

final class FakeImportService: ImportService, @unchecked Sendable {
    static let rawText = "Day 1\n10:00 광장시장\nXXX Shoes 買鞋\n19:00 晚餐訂位 Some Restaurant"
    static let session = ImportSession(id: UUID(), tripName: "UI Test Seoul", startDate: "2026-10-01", endDate: "2026-10-02",
                                       timeZone: "Asia/Seoul", rawText: rawText, parseStatus: .pending)

    private let lock = NSLock()
    private var remainingFailures: Int

    init(failFirst: Bool) {
        remainingFailures = failFirst ? 1 : 0
    }

    func createImport(tripName: String, startDate: String, endDate: String, timeZone: String, rawText: String) async throws -> ImportSession {
        Self.session
    }

    func updateText(importID: UUID, rawText: String) async throws -> ImportSession {
        var s = Self.session
        s.rawText = rawText
        return s
    }

    func parse(importID: UUID) async throws -> ImportSession {
        try await Task.sleep(for: .milliseconds(300))
        var s = Self.session
        let fail = lock.withLock { () -> Bool in
            defer { remainingFailures = max(0, remainingFailures - 1) }
            return remainingFailures > 0
        }
        if fail {
            s.parseStatus = .failed
            s.parseError = "provider_error"
            return s
        }
        s.parseStatus = .parsed
        s.parseResult = .init(draft: ParseDraft(days: [
            .init(date: "2026-10-01", dayLabel: "Day 1", stops: [
                ParsedStop(sourceExcerpt: "10:00 광장시장", placeName: "광장시장", category: "eat", startTime: "10:00"),
                ParsedStop(sourceExcerpt: "XXX Shoes 買鞋", placeName: "XXX Shoes", category: "shop", needsConfirmation: [.ambiguousBranch]),
                ParsedStop(sourceExcerpt: "19:00 晚餐訂位 Some Restaurant", placeName: "Some Restaurant", category: "eat",
                           startTime: "19:00", fixedSuspected: true, fixedReason: "訂位"),
            ]),
        ], cityCandidates: ["Seoul"], warnings: []))
        return s
    }

    func session(importID: UUID) async throws -> ImportSession {
        var s = Self.session
        s.parseStatus = .parsing
        s.parseProgress = ParseProgress(stage: "writing", days: 1, stops: 2, lastPlace: "XXX Shoes")
        return s
    }

    func registerPlace(_ draft: PlaceDraft) async throws -> Place {
        Place(id: UUID(), provider: draft.provider.rawValue, providerPlaceId: draft.providerPlaceId, name: draft.name,
              nameLocal: nil, address: draft.address, latitude: draft.latitude, longitude: draft.longitude, countryCode: draft.countryCode)
    }

    func commit(importID: UUID, days: [ImportDayCommit]) async throws -> Trip {
        Trip(id: UUID(), name: Self.session.tripName, startDate: "2026-10-01", endDate: "2026-10-02", timeZone: "Asia/Seoul", revision: 1)
    }
}

struct FakePlaceSearch: PlaceSearching {
    func search(_ query: String, near city: String?, limit: Int) async -> [PlaceOption] {
        func option(_ name: String, _ lat: Double) -> PlaceOption {
            PlaceOption(draft: PlaceDraft(providerPlaceId: name, name: name, address: "서울", latitude: lat, longitude: 127, countryCode: "KR"))
        }
        switch query {
        case "XXX Shoes": return [option("XXX Shoes 명동점", 37.56), option("XXX Shoes 성수점", 37.54)]
        case "광장시장": return [option("광장시장", 37.57)]
        case "Some Restaurant": return [option("Some Restaurant", 37.55)]
        default: return []
        }
    }
}
#endif

#if DEBUG
/// XCUITest：`-UITestShopping 1` 直接進 Shopping（假服務）。
public struct ShoppingUITestRoot: View {
    @State private var service = FakeShoppingService()
    @State private var token = 0

    public init() {}

    public var body: some View {
        NavigationStack {
            ShoppingListView(service: service, tripID: FakeShoppingService.tripID, canEdit: true, queue: nil, reloadToken: token) { _ in
                Text("merchant")
            }
            .navigationTitle("購物清單")
        }
    }
}

final class FakeShoppingService: ShoppingService, @unchecked Sendable {
    static let tripID = UUID()
    let me = UUID()
    private var items: [ShoppingItem] = []
    private var events: [PurchaseEvent] = []
    private let lock = NSLock()

    var currentUserID: UUID? { me }

    func shoppingEntries(of tripID: UUID) async throws -> [ShoppingEntry] {
        lock.withLock { items.map { item in ShoppingEntry(item: item, interestedUserIDs: [me], events: events.filter { $0.itemId == item.id }) } }
    }

    func addShoppingItem(tripID: UUID, name: String, note: String?, url: String?, clientOpID: UUID?) async throws -> ShoppingItem {
        lock.withLock {
            let item = ShoppingItem(id: UUID(), tripId: tripID, name: name, addedBy: me)
            items.append(item)
            return item
        }
    }

    func recordPurchase(itemID: UUID, purchased: Bool, clientOpID: UUID?) async throws {
        lock.withLock { events.append(PurchaseEvent(id: events.count, itemId: itemID, actorId: me, type: purchased ? .purchased : .undone, createdAt: Date())) }
    }

    func setShoppingInterest(itemID: UUID, interested: Bool) async throws {}
    func merchants(of itemID: UUID) async throws -> [MerchantCandidate] { [] }
    func addMerchant(itemID: UUID, placeID: UUID, evidence: MerchantCandidate.EvidenceType, url: String?, note: String?) async throws {}
}

/// 刻意延遲內容，重現清單先完成但行程尚未到達的啟動順序。
private struct StartupUITestScene: View {
    @State private var store: TripStore
    init(failFirst: Bool) { _store = State(initialValue: TripStore(dataSource: StartupUITestSource(failFirst: failFirst))) }
    var body: some View {
        Group {
            if store.snapshot != nil {
                Text("已載入測試旅程").accessibilityIdentifier("startupReady")
            } else {
                TripUnavailableView(store: store, systemImage: "sun.max", goToTrips: {})
            }
        }
        .navigationTitle("今天")
        .task { await store.start() }
    }
}
private actor StartupUITestSource: TripStoreDataSource {
    enum Failure: Error { case offline }
    var failFirst: Bool
    let trip = Trip(id: UUID(), name: "測試旅程", startDate: "2026-10-01", endDate: "2026-10-01", timeZone: "Asia/Tokyo", revision: 0)
    init(failFirst: Bool) { self.failFirst = failFirst }
    func myTrips() async throws -> [Trip] { [trip] }
    func snapshot(of trip: Trip) async throws -> TripSnapshot {
        try await Task.sleep(for: .seconds(3))
        if failFirst { failFirst = false; throw Failure.offline }
        return TripSnapshot(trip: trip, revision: 0, timeline: [], places: [:], saved: [], shopping: [])
    }
}

/// 使用真正的收藏列及外開地圖元件；攔截 URL，測試不離開 App、不連網。
private struct SavedButtonsUITestScene: View {
    let personal: Bool
    var failFirst = false
    var viewer = false
    var multiple = false
    var confirmFails = false
    @State private var confirmedItem: InboxItemRecord?
    @State private var confirmations = 0
    @State private var removed = false
    @State private var attempts = 0
    @State private var opened = 0
    @State private var interested = 0
    @State private var scheduled = 0
    @State private var mapOpens = 0
    @State private var mapQuery = "尚未開啟"
    private let repository = InboxRepository(client: SupabaseClient(supabaseURL: URL(string: "https://example.invalid")!, supabaseKey: "ui-test"))
    private let entry = SavedEntry(saved: SavedPlace(id: UUID(), tripId: UUID(), placeId: nil,
        rawLabel: "測試收藏", category: .eat, sourceId: nil, addedBy: nil, status: .saved),
        place: nil, source: nil, interestedUserIDs: [])
    private var item: InboxItemRecord {
        if let confirmedItem { return confirmedItem }
        var value = try! JSONDecoder().decode(InboxItemRecord.self, from: Data(#"""
        {"id":"00000000-0000-0000-0000-000000000001","capture_id":"00000000-0000-0000-0000-000000000002",
         "kind":"place","display_name":"測試個人收藏","source_span":"image:1","confidence":"low","origin_type":"explicit",
         "resolution_status":"unresolved","archived":true,"revision":0,
         "discovery_candidates":[{"name":"測試餐廳","korean_name":"테스트 식당","address_local":"서울 성동구 연무장길 12-1",
           "search_query":"測試店名","reason":"測試來源","source_url":"https://example.invalid/source"}]}
        """#.utf8))
        if multiple, var second = value.discoveryCandidates?.first {
            second.name = "第二間餐廳"
            second.koreanName = "두 번째 식당"
            second.sourceURL = "https://example.invalid/second"
            value.discoveryCandidates?.append(second)
        }
        return value
    }
    var body: some View {
        List {
            Section {
                Text("詳情 \(opened) · 想去 \(interested) · 排程 \(scheduled)").accessibilityIdentifier("actionCounts")
                Text("地圖 \(mapOpens)").accessibilityIdentifier("mapOpenCount")
                Text(mapQuery).accessibilityIdentifier("mapQuery")
            }
            if personal {
                PersonalInboxRow(item: item, kind: "place", repository: repository,
                    onUpdated: { confirmedItem = $0 }, confirmDiscovery: { original, index in
                        confirmations += 1
                        if confirmFails && confirmations == 1 { throw BackendError.staleRevision }
                        var result = original
                        result.confirmedDiscovery = original.discoveryCandidates?[index]
                        result.revision += 1
                        result.archived = true
                        return result
                    })
            } else if !removed {
                SavedRow(entry: entry, me: nil, canEdit: !viewer, scheduledDay: nil,
                         toggleInterest: { interested += 1 }, schedule: { scheduled += 1 },
                         showDay: {}, open: { opened += 1 }, remove: {
                             attempts += 1
                             if failFirst && attempts == 1 { throw BackendError.staleRevision }
                             removed = true
                         })
            } else {
                Text("已移除收藏").accessibilityIdentifier("collectionRemoved")
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            mapOpens += 1
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            mapQuery = components?.queryItems?.first { $0.name == "q" || $0.name == "query" }?.value
                ?? components?.path.replacingOccurrences(of: "/p/search/", with: "") ?? ""
            return .handled
        })
    }
}
#endif
