import Foundation
import Supabase

public enum SavedCategory: String, Codable, CaseIterable, Sendable {
    case eat, cafe, shop, place, other

    public var displayName: String {
        switch self {
        case .eat: "美食"
        case .cafe: "咖啡"
        case .shop: "購物"
        case .place: "景點"
        case .other: "其他"
        }
    }

    /// 停留預設（§4.2）。
    public var defaultDwellMinutes: Int {
        switch self {
        case .cafe: 45
        case .shop: 30
        default: 60
        }
    }
}

public struct SavedPlace: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case saved
        case addedToItinerary = "added_to_itinerary"
        case dismissed
    }

    public var id: UUID
    public var tripId: UUID
    /// nil = 地點未確認，不參與路線。
    public var placeId: UUID?
    public var rawLabel: String
    public var category: SavedCategory
    public var sourceId: UUID?
    /// nil = 新增者已刪除帳號（匿名化）。
    public var addedBy: UUID?
    public var status: Status
    /// 截圖或有來源的網頁查得的地址線索；不代表已確認座標。
    public var addressHint: String?
    public var addressSourceURL: String?

    public init(id: UUID, tripId: UUID, placeId: UUID?, rawLabel: String, category: SavedCategory, sourceId: UUID?, addedBy: UUID?, status: Status,
                addressHint: String? = nil, addressSourceURL: String? = nil) {
        self.id = id
        self.tripId = tripId
        self.placeId = placeId
        self.rawLabel = rawLabel
        self.category = category
        self.sourceId = sourceId
        self.addedBy = addedBy
        self.status = status
        self.addressHint = addressHint
        self.addressSourceURL = addressSourceURL
    }

    enum CodingKeys: String, CodingKey {
        case id, category, status
        case tripId = "trip_id"
        case placeId = "place_id"
        case rawLabel = "raw_label"
        case sourceId = "source_id"
        case addedBy = "added_by"
        case addressHint = "address_hint"
        case addressSourceURL = "address_source_url"
    }
}

public struct SourceReference: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var type: String
    public var url: String?
    public var canonicalUrl: String?
    public var summary: String?

    enum CodingKeys: String, CodingKey {
        case id, type, url, summary
        case canonicalUrl = "canonical_url"
    }
}

/// `save_place` 的來源參數。
public struct SavedSource: Codable, Equatable, Sendable {
    public var type: String
    public var url: String?
    public var canonicalUrl: String?
    public var summary: String?

    public init(type: String = "share", url: String?, canonicalUrl: String?, summary: String?) {
        self.type = type
        self.url = url
        self.canonicalUrl = canonicalUrl
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case type, url, summary
        case canonicalUrl = "canonical_url"
    }
}

/// 一筆 Saved 加上顯示所需資料。
public struct SavedEntry: Identifiable, Codable, Hashable, Sendable {
    public var saved: SavedPlace
    public var place: Place?
    public var source: SourceReference?
    public var interestedUserIDs: Set<UUID>

    public var id: UUID { saved.id }
    public var title: String { place?.displayTitle(fallbackChinese: saved.rawLabel) ?? saved.rawLabel }
    public var isConfirmed: Bool { saved.placeId != nil }
    public var addressLabel: String? { place?.localAddress ?? saved.addressHint ?? place?.address }

    public init(saved: SavedPlace, place: Place?, source: SourceReference?, interestedUserIDs: Set<UUID>) {
        self.saved = saved
        self.place = place
        self.source = source
        self.interestedUserIDs = interestedUserIDs
    }
}

/// Saved 分頁的篩選規則（規格 §3.5）。
public enum SavedFilter: Hashable, Sendable {
    case all
    case category(SavedCategory)

    public static let tabs: [SavedFilter] = [.all, .category(.eat), .category(.shop), .category(.cafe), .category(.place)]

    public var title: String {
        switch self {
        case .all: "全部"
        case .category(let c): c.displayName
        }
    }

    /// 已加入行程或已移除的不出現在待加入清單；想去人數多的排前面。
    public func apply(_ entries: [SavedEntry], includeAdded: Bool = false) -> [SavedEntry] {
        entries
            .filter { $0.saved.status == .saved || (includeAdded && $0.saved.status == .addedToItinerary) }
            .filter {
                switch self {
                case .all: true
                case .category(let c): $0.saved.category == c
                }
            }
            .sorted { $0.interestedUserIDs.count > $1.interestedUserIDs.count }
    }
}

extension TripRepository {
    /// 未移除的 Saved，含地點、來源與想去成員。
    public func savedEntries(of tripID: UUID) async throws -> [SavedEntry] {
        struct Interest: Decodable { let saved_id: UUID, user_id: UUID }
        do {
            let saved: [SavedPlace] = try await client.from("saved_places").select()
                .eq("trip_id", value: tripID).neq("status", value: "dismissed").order("created_at", ascending: false)
                .execute().value
            guard !saved.isEmpty else { return [] }
            let ids = saved.map(\.id.uuidString)
            async let interestsReq: [Interest] = client.from("saved_interests").select().in("saved_id", values: ids).execute().value
            async let sourcesReq: [SourceReference] = client.from("source_references").select()
                .in("id", values: saved.compactMap(\.sourceId?.uuidString)).execute().value
            async let placesReq = places(ids: saved.compactMap(\.placeId))
            let (interests, sources, placeList) = try await (interestsReq, sourcesReq, placesReq)
            let placeByID = Dictionary(uniqueKeysWithValues: placeList.map { ($0.id, $0) })
            let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
            let interestBySaved = Dictionary(grouping: interests, by: \.saved_id).mapValues { Set($0.map(\.user_id)) }
            return saved.map {
                SavedEntry(saved: $0, place: $0.placeId.flatMap { placeByID[$0] }, source: $0.sourceId.flatMap { sourceByID[$0] },
                           interestedUserIDs: interestBySaved[$0.id] ?? [])
            }
        } catch {
            throw BackendError.from(error)
        }
    }

    /// 回傳該筆 Saved 與是否為重複（重複時只記錄想去，不新增）。
    public func savePlace(tripID: UUID, label: String, category: SavedCategory, placeID: UUID?, source: SavedSource?,
                          clientOpID: UUID? = nil) async throws -> (SavedPlace, duplicate: Bool) {
        struct Params: Encodable {
            let p_trip_id: UUID, p_raw_label: String, p_category: SavedCategory, p_place_id: UUID?, p_source: SavedSource?
            let p_client_op_id: UUID?
        }
        struct Result: Decodable {
            let saved: SavedPlace, duplicate: Bool
            init(from decoder: any Decoder) throws {
                saved = try SavedPlace(from: decoder)
                duplicate = try decoder.container(keyedBy: Key.self).decode(Bool.self, forKey: .duplicate)
            }
            enum Key: String, CodingKey { case duplicate }
        }
        do {
            let r: Result = try await client.rpc("save_place", params: Params(
                p_trip_id: tripID, p_raw_label: label, p_category: category, p_place_id: placeID, p_source: source,
                p_client_op_id: clientOpID
            )).execute().value
            return (r.saved, r.duplicate)
        } catch {
            throw BackendError.from(error)
        }
    }

    public func setInterest(savedID: UUID, interested: Bool) async throws {
        struct Params: Encodable { let p_saved_id: UUID, p_interested: Bool }
        do { try await client.rpc("set_saved_interest", params: Params(p_saved_id: savedID, p_interested: interested)).execute() }
        catch { throw BackendError.from(error) }
    }

    public func setSavedAddressHint(savedID: UUID, address: String, sourceURL: String?) async throws {
        struct Params: Encodable { let p_saved_id: UUID, p_address_hint: String, p_source_url: String? }
        do {
            try await client.rpc("set_saved_address_hint", params: Params(
                p_saved_id: savedID, p_address_hint: address, p_source_url: sourceURL
            )).execute()
        } catch { throw BackendError.from(error) }
    }

    public func resolveSaved(savedID: UUID, placeID: UUID) async throws {
        struct Params: Encodable { let p_saved_id: UUID, p_place_id: UUID }
        do { try await client.rpc("resolve_saved", params: Params(p_saved_id: savedID, p_place_id: placeID)).execute() }
        catch { throw BackendError.from(error) }
    }

    public func dismissSaved(savedID: UUID) async throws {
        struct Params: Encodable { let p_saved_id: UUID }
        do { try await client.rpc("dismiss_saved", params: Params(p_saved_id: savedID)).execute() }
        catch { throw BackendError.from(error) }
    }

    public var currentUserID: UUID? {
        client.auth.currentUser?.id
    }

    /// 讀取（必要時更新）共用 Keychain 裡的 session；未登入或過期無法更新時為 false。
    public func isSignedIn() async -> Bool {
        (try? await client.auth.session) != nil
    }
}
