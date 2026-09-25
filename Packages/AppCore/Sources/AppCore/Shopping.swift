import Foundation
import Supabase

public struct ShoppingItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var tripId: UUID
    public var name: String
    public var note: String?
    public var url: String?
    /// nil = 新增者已刪除帳號（匿名化）。
    public var addedBy: UUID?
    public var plannedStopId: UUID?

    public init(id: UUID, tripId: UUID, name: String, note: String? = nil, url: String? = nil, addedBy: UUID?, plannedStopId: UUID? = nil) {
        self.id = id
        self.tripId = tripId
        self.name = name
        self.note = note
        self.url = url
        self.addedBy = addedBy
        self.plannedStopId = plannedStopId
    }

    enum CodingKeys: String, CodingKey {
        case id, name, note, url
        case tripId = "trip_id"
        case addedBy = "added_by"
        case plannedStopId = "planned_stop_id"
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
    func addMerchant(itemID: UUID, placeID: UUID, evidence: MerchantCandidate.EvidenceType, url: String?, note: String?) async throws
    var currentUserID: UUID? { get }
}

extension TripRepository: ShoppingService {
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
                return ShoppingEntry(item: item, interestedUserIDs: interestByItem[item.id] ?? [], events: eventsByItem[item.id] ?? [],
                                     plannedDate: stop.flatMap { dayByID[$0.dayId]?.localDate }, plannedStore: place.map { $0.displayTitle })
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
