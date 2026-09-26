import Foundation
import Supabase

/// 可回查的店家線索；尚未確認此商品在該店販售，也沒有庫存資訊。
public struct ShoppingStoreSuggestion: Codable, Hashable, Sendable {
    public var name: String
    public var koreanName: String?
    public var addressLocal: String?
    public var searchQuery: String
    public var reason: String
    public var sourceURL: String

    public var displayName: String { koreanName ?? name }

    public init(name: String, koreanName: String?, addressLocal: String?, searchQuery: String,
                reason: String, sourceURL: String) {
        self.name = name
        self.koreanName = koreanName
        self.addressLocal = addressLocal
        self.searchQuery = searchQuery
        self.reason = reason
        self.sourceURL = sourceURL
    }

    enum CodingKeys: String, CodingKey {
        case name, reason
        case koreanName = "korean_name"
        case addressLocal = "address_local"
        case searchQuery = "search_query"
        case sourceURL = "source_url"
    }
}

public struct ShoppingItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var tripId: UUID
    public var name: String
    public var note: String?
    public var url: String?
    /// nil = 新增者已刪除帳號（匿名化）。
    public var addedBy: UUID?
    public var plannedStopId: UUID?
    /// 私有 bucket `shopping-images` 內的路徑（`<trip_id>/<檔名>`）；顯示時換成簽名網址。
    public var imagePath: String?
    /// 分享內容提到的店名；只是搜尋線索，不能當販售或庫存事實。
    public var storeHint: String?
    public var storeEvidence: String?
    public var storeSuggestions: [ShoppingStoreSuggestion]?
    public var storeSuggestionsChecked: Bool?

    public var savedStoreSuggestions: [ShoppingStoreSuggestion] { storeSuggestions ?? [] }

    public init(id: UUID, tripId: UUID, name: String, note: String? = nil, url: String? = nil, addedBy: UUID?, plannedStopId: UUID? = nil,
                imagePath: String? = nil, storeHint: String? = nil, storeEvidence: String? = nil,
                storeSuggestions: [ShoppingStoreSuggestion]? = nil, storeSuggestionsChecked: Bool? = nil) {
        self.id = id
        self.tripId = tripId
        self.name = name
        self.note = note
        self.url = url
        self.addedBy = addedBy
        self.plannedStopId = plannedStopId
        self.imagePath = imagePath
        self.storeHint = storeHint
        self.storeEvidence = storeEvidence
        self.storeSuggestions = storeSuggestions
        self.storeSuggestionsChecked = storeSuggestionsChecked
    }

    enum CodingKeys: String, CodingKey {
        case id, name, note, url
        case tripId = "trip_id"
        case addedBy = "added_by"
        case plannedStopId = "planned_stop_id"
        case imagePath = "image_path"
        case storeHint = "store_hint"
        case storeEvidence = "store_evidence"
        case storeSuggestions = "store_suggestions"
        case storeSuggestionsChecked = "store_suggestions_checked"
    }
}

public struct MerchantCandidate: Codable, Identifiable, Hashable, Sendable {
    public enum EvidenceType: String, Codable, Sendable {
        case officialLocator = "official_locator"
        case poiCategory = "poi_category"
        case user

        public var displayName: String {
            switch self {
            case .officialLocator: "官方店鋪查詢"
            case .poiCategory: "地圖搜尋結果"
            case .user: "使用者提供"
            }
        }
    }

    public var id: UUID
    public var itemId: UUID
    public var placeId: UUID
    public var evidenceType: EvidenceType
    public var evidenceUrl: String?
    public var evidenceNote: String?
    public var expiresAt: Date
    /// MVP 只有 unknown：「可能販售」不等於「有庫存」（規格規則 6）。
    public var inventoryStatus: String

    public func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }

    enum CodingKeys: String, CodingKey {
        case id
        case itemId = "item_id"
        case placeId = "place_id"
        case evidenceType = "evidence_type"
        case evidenceUrl = "evidence_url"
        case evidenceNote = "evidence_note"
        case expiresAt = "expires_at"
        case inventoryStatus = "inventory_status"
    }
}

/// 已排進行程、且同一地點有尚未過期販售線索的停靠點。只表示可能販售，不代表有庫存。
public struct ShoppingItineraryMatch: Identifiable, Hashable, Sendable {
    public var itemID: UUID
    public var stopID: UUID
    public var dayNumber: Int
    public var placeName: String
    /// nil 代表商品品牌與店名相符的待確認建議，不是販售證據。
    public var evidenceType: MerchantCandidate.EvidenceType?
    public var evidenceURL: String?
    public var evidenceNote: String?

    public var id: UUID { stopID }

    public init(itemID: UUID, stopID: UUID, dayNumber: Int, placeName: String,
                evidenceType: MerchantCandidate.EvidenceType?, evidenceURL: String?, evidenceNote: String?) {
        self.itemID = itemID
        self.stopID = stopID
        self.dayNumber = dayNumber
        self.placeName = placeName
        self.evidenceType = evidenceType
        self.evidenceURL = evidenceURL
        self.evidenceNote = evidenceNote
    }

    /// 未定位或線索過期的地點不會被當作可購買地點；同一間店可列在不同天。
    public static func find(items: [ShoppingItem], stops: [Stop], days: [TripDay], places: [Place], candidates: [MerchantCandidate],
                            now: Date = Date()) -> [UUID: [ShoppingItineraryMatch]] {
        let daysByID = Dictionary(uniqueKeysWithValues: days.map { ($0.id, $0) })
        let placesByID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        let candidatesByPlace = Dictionary(grouping: candidates.filter { !$0.isExpired(now: now) }, by: \.placeId)
        var matches: [UUID: [ShoppingItineraryMatch]] = [:]
        for stop in stops where stop.isRoutable {
            guard let placeID = stop.placeId, let place = placesByID[placeID], let day = daysByID[stop.dayId] else { continue }
            for candidate in candidatesByPlace[placeID] ?? [] {
                matches[candidate.itemId, default: []].append(ShoppingItineraryMatch(
                    itemID: candidate.itemId, stopID: stop.id, dayNumber: day.displayOrder + 1,
                    placeName: place.displayTitle(fallbackChinese: stop.rawLabel),
                    evidenceType: candidate.evidenceType, evidenceURL: candidate.evidenceUrl,
                    evidenceNote: candidate.evidenceNote))
            }
            // 沒有販售證據時，只用足夠明確的品牌／店名文字提出「可詢問」建議。
            // 不把商品類別或附近商場推成實際販售點。
            for item in items where !(candidatesByPlace[placeID] ?? []).contains(where: { $0.itemId == item.id }) {
                guard Self.storeMatches(item, place: place) else { continue }
                matches[item.id, default: []].append(ShoppingItineraryMatch(
                    itemID: item.id, stopID: stop.id, dayNumber: day.displayOrder + 1,
                    placeName: place.displayTitle(fallbackChinese: stop.rawLabel),
                    evidenceType: nil, evidenceURL: nil,
                    evidenceNote: item.storeHint.map { "分享內容提到的店名：\($0)" }))
            }
        }
        return matches.mapValues { $0.sorted { ($0.dayNumber, $0.placeName) < ($1.dayNumber, $1.placeName) } }
    }

    private static func storeMatches(_ item: ShoppingItem, place: Place) -> Bool {
        let first = item.name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "・" }).first.map(String.init)
        let terms: [(text: String, explicit: Bool)] = [item.storeHint.map { ($0, true) }, first.map { ($0, false) }].compactMap { $0 }
        let storeNames = [place.name, place.nameLocal, place.nameZh].compactMap { $0 }
        return terms.contains { term in
            let normalizedTerm = term.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let distinctiveShortBrand = term.text.count >= 3 && term.text.allSatisfy { $0.isASCII && $0.isUppercase }
            guard normalizedTerm.rangeOfCharacter(from: .letters) != nil,
                  normalizedTerm.count >= 4 || (term.explicit && normalizedTerm.count >= 2) || distinctiveShortBrand else { return false }
            return storeNames.contains { name in
                let normalizedName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if normalizedTerm.count < 4 {
                    return normalizedName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == normalizedTerm }
                }
                return normalizedName.contains(normalizedTerm)
            }
        }
    }
}

public struct PurchaseEvent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case purchased, undone }
    public var id: Int
    public var itemId: UUID
    /// nil = 購買者已刪除帳號（匿名化）。
    public var actorId: UUID?
    public var type: Kind
    public var createdAt: Date

    public init(id: Int, itemId: UUID, actorId: UUID?, type: Kind, createdAt: Date) {
        self.id = id
        self.itemId = itemId
        self.actorId = actorId
        self.type = type
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, type
        case itemId = "item_id"
        case actorId = "actor_id"
        case createdAt = "created_at"
    }
}

/// 一個商品與顯示所需的資料；狀態由事件推導（§3.4）。
public struct ShoppingEntry: Identifiable, Codable, Hashable, Sendable {
    public var item: ShoppingItem
    public var interestedUserIDs: Set<UUID>
    public var events: [PurchaseEvent]
    /// 已安排時的 Purchase Stop 所在日（當地日期）與店名。
    public var plannedDate: String?
    public var plannedStore: String?
    /// 已安排在旅程的第幾天（1 起算），畫面用「第 N 天」而不是日期字串。
    public var plannedDayNumber: Int?

    public var id: UUID { item.id }

    public enum Status: Equatable, Sendable {
        case unscheduled
        case scheduled
        case purchased(by: UUID?, at: Date)
    }

    public var status: Status {
        if let last = events.max(by: { $0.id < $1.id }), last.type == .purchased {
            return .purchased(by: last.actorId, at: last.createdAt)
        }
        return item.plannedStopId == nil ? .unscheduled : .scheduled
    }

    public var isPurchased: Bool {
        if case .purchased = status { true } else { false }
    }

    public init(item: ShoppingItem, interestedUserIDs: Set<UUID>, events: [PurchaseEvent], plannedDate: String? = nil, plannedStore: String? = nil) {
        self.item = item
        self.interestedUserIDs = interestedUserIDs
        self.events = events
        self.plannedDate = plannedDate
        self.plannedStore = plannedStore
    }
}

public struct ShoppingProgress: Equatable, Sendable {
    public var purchased: Int
    public var total: Int

    public init(_ entries: [ShoppingEntry]) {
        total = entries.count
        purchased = entries.filter(\.isPurchased).count
    }
}

/// 今日可買（Today）：只算已安排在當日且未購買的（AC-09）。
public enum TodayShopping {
    public static func items(_ entries: [ShoppingEntry], on date: String) -> [ShoppingEntry] {
        entries.filter { $0.status == .scheduled && $0.plannedDate == date }
    }
}

public protocol ShoppingService: Sendable {
    func shoppingEntries(of tripID: UUID) async throws -> [ShoppingEntry]
    func addShoppingItem(tripID: UUID, name: String, note: String?, url: String?, clientOpID: UUID?) async throws -> ShoppingItem
    func recordPurchase(itemID: UUID, purchased: Bool, clientOpID: UUID?) async throws
    func setShoppingInterest(itemID: UUID, interested: Bool) async throws
    func merchants(of itemID: UUID) async throws -> [MerchantCandidate]
    func itineraryMatches(tripID: UUID, items: [ShoppingItem]) async throws -> [UUID: [ShoppingItineraryMatch]]
    func addMerchant(itemID: UUID, placeID: UUID, evidence: MerchantCandidate.EvidenceType, url: String?, note: String?) async throws
    var currentUserID: UUID? { get }
    /// 上傳商品照片（JPEG）並設到商品上。
    func setShoppingImage(tripID: UUID, itemID: UUID, jpeg: Data) async throws
    /// 照片的暫時網址（私有 bucket 的簽名網址）；沒有或讀不到時為 nil。
    func shoppingImageURL(path: String) async -> URL?
}

extension ShoppingService {
    public func itineraryMatches(tripID: UUID, items: [ShoppingItem]) async throws -> [UUID: [ShoppingItineraryMatch]] { [:] }
    public func setShoppingImage(tripID: UUID, itemID: UUID, jpeg: Data) async throws {}
    public func shoppingImageURL(path: String) async -> URL? { nil }
}

extension TripRepository: ShoppingService {
    public func setShoppingStoreHint(itemID: UUID, name: String, evidence: String?) async throws {
        struct Params: Encodable { let p_item_id: UUID, p_store_hint: String, p_store_evidence: String? }
        do {
            try await client.rpc("set_shopping_store_hint", params: Params(
                p_item_id: itemID, p_store_hint: name, p_store_evidence: evidence)).execute()
        } catch { throw BackendError.from(error) }
    }

    public func setShoppingStoreSuggestions(itemID: UUID, suggestions: [ShoppingStoreSuggestion]) async throws {
        struct Params: Encodable { let p_item_id: UUID, p_suggestions: [ShoppingStoreSuggestion] }
        do {
            try await client.rpc("set_shopping_store_suggestions", params: Params(
                p_item_id: itemID, p_suggestions: Array(suggestions.prefix(3)))).execute()
        } catch { throw BackendError.from(error) }
    }

    public func itineraryMatches(tripID: UUID, items: [ShoppingItem]) async throws -> [UUID: [ShoppingItineraryMatch]] {
        guard !items.isEmpty else { return [:] }
        do {
            async let daysRequest = days(of: tripID)
            async let stopsRequest = stops(of: tripID)
            let candidates: [MerchantCandidate] = try await client.from("merchant_candidates").select()
                .in("item_id", values: items.map { $0.id.uuidString }).execute().value
            let (days, stops) = try await (daysRequest, stopsRequest)
            let places = try await places(ids: Array(Set(stops.compactMap(\.placeId))))
            return ShoppingItineraryMatch.find(items: items, stops: stops, days: days, places: places, candidates: candidates)
        } catch {
            throw BackendError.from(error)
        }
    }

    public func shoppingEntries(of tripID: UUID) async throws -> [ShoppingEntry] {
        struct Interest: Decodable { let item_id: UUID, user_id: UUID }
        do {
            let items: [ShoppingItem] = try await client.from("shopping_items").select()
                .eq("trip_id", value: tripID).is("deleted_at", value: nil).order("created_at").execute().value
            guard !items.isEmpty else { return [] }
            let ids = items.map(\.id.uuidString)
            async let interestsReq: [Interest] = client.from("shopping_interests").select().in("item_id", values: ids).execute().value
            async let eventsReq: [PurchaseEvent] = client.from("purchase_events").select().in("item_id", values: ids).order("id").execute().value
            async let daysReq = days(of: tripID)
            async let stopsReq = stops(of: tripID)
            let (interests, events, days, stops) = try await (interestsReq, eventsReq, daysReq, stopsReq)
            let placeList = try await places(ids: stops.compactMap(\.placeId))
            let placeByID = Dictionary(uniqueKeysWithValues: placeList.map { ($0.id, $0) })
            let dayByID = Dictionary(uniqueKeysWithValues: days.map { ($0.id, $0) })
            let stopByID = Dictionary(uniqueKeysWithValues: stops.map { ($0.id, $0) })
            let interestByItem = Dictionary(grouping: interests, by: \.item_id).mapValues { Set($0.map(\.user_id)) }
            let eventsByItem = Dictionary(grouping: events, by: \.itemId)
            return items.map { item in
                let stop = item.plannedStopId.flatMap { stopByID[$0] }
                let place = stop?.placeId.flatMap { placeByID[$0] }
                var entry = ShoppingEntry(item: item, interestedUserIDs: interestByItem[item.id] ?? [], events: eventsByItem[item.id] ?? [],
                                          plannedDate: stop.flatMap { dayByID[$0.dayId]?.localDate }, plannedStore: place.map { $0.displayTitle })
                entry.plannedDayNumber = stop.flatMap { dayByID[$0.dayId] }.map { $0.displayOrder + 1 }
                return entry
            }
        } catch {
            throw BackendError.from(error)
        }
    }

    public func addShoppingItem(tripID: UUID, name: String, note: String?, url: String?, clientOpID: UUID?) async throws -> ShoppingItem {
        struct Params: Encodable { let p_trip_id: UUID, p_name: String, p_note: String?, p_url: String?, p_client_op_id: UUID? }
        do {
            return try await client.rpc("add_shopping_item", params: Params(p_trip_id: tripID, p_name: name, p_note: note, p_url: url, p_client_op_id: clientOpID)).execute().value
        } catch { throw BackendError.from(error) }
    }

    public func recordPurchase(itemID: UUID, purchased: Bool, clientOpID: UUID?) async throws {
        struct Params: Encodable { let p_item_id: UUID, p_purchased: Bool, p_client_op_id: UUID? }
        do { try await client.rpc("record_purchase", params: Params(p_item_id: itemID, p_purchased: purchased, p_client_op_id: clientOpID)).execute() }
        catch { throw BackendError.from(error) }
    }

    public func setShoppingInterest(itemID: UUID, interested: Bool) async throws {
        struct Params: Encodable { let p_item_id: UUID, p_interested: Bool }
        do { try await client.rpc("set_shopping_interest", params: Params(p_item_id: itemID, p_interested: interested)).execute() }
        catch { throw BackendError.from(error) }
    }

    public func merchants(of itemID: UUID) async throws -> [MerchantCandidate] {
        do { return try await client.from("merchant_candidates").select().eq("item_id", value: itemID).execute().value }
        catch { throw BackendError.from(error) }
    }

    public func addMerchant(itemID: UUID, placeID: UUID, evidence: MerchantCandidate.EvidenceType, url: String?, note: String?) async throws {
        struct Params: Encodable {
            let p_item_id: UUID, p_place_id: UUID, p_evidence_type: MerchantCandidate.EvidenceType, p_evidence_url: String?, p_evidence_note: String?
        }
        do {
            try await client.rpc("add_merchant_candidate", params: Params(p_item_id: itemID, p_place_id: placeID, p_evidence_type: evidence,
                                                                          p_evidence_url: url, p_evidence_note: note)).execute()
        } catch { throw BackendError.from(error) }
    }
}
