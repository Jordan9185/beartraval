import Foundation

public enum ResolutionStatus: String, Codable, Sendable {
    case resolved
    /// 地點未確認：沒有 place，不參與路線計算（規格 §1）。
    case pendingText = "pending_text"
}

public enum StopKind: String, Codable, Sendable {
    case standard
    case purchase
}

public struct Place: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: String
    public var providerPlaceId: String
    public var name: String
    /// 在地語言名稱（例如韓文店名），外開 Naver／Kakao 用。
    public var nameLocal: String?
    public var address: String?
    public var latitude: Double
    public var longitude: Double
    public var countryCode: String?
    /// 繁體中文名稱（顯示在原文旁）。
    public var nameZh: String?
    /// 當地文字的地址（韓文、日文）：Apple 依手機語言回傳地址，中文手機會拿到「南韓首爾特別市…」，
    /// 司機看不懂，所以另外存一份。
    public var addressLocal: String?

    public init(id: UUID, provider: String, providerPlaceId: String, name: String, nameLocal: String?, address: String?,
                latitude: Double, longitude: Double, countryCode: String?, nameZh: String? = nil, addressLocal: String? = nil) {
        self.id = id
        self.provider = provider
        self.providerPlaceId = providerPlaceId
        self.name = name
        self.nameLocal = nameLocal
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.countryCode = countryCode
        self.nameZh = nameZh
        self.addressLocal = addressLocal
    }

    /// 外開當地地圖、給司機看時用的地址：有當地文字的就用它。
    public var localAddress: String? { addressLocal ?? address }

    enum CodingKeys: String, CodingKey {
        case id, provider, name, address, latitude, longitude
        case providerPlaceId = "provider_place_id"
        case nameLocal = "name_local"
        case countryCode = "country_code"
        case nameZh = "name_zh"
        case addressLocal = "address_local"
    }
}

public struct Stop: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var tripId: UUID
    public var dayId: UUID
    public var placeId: UUID?
    public var rawLabel: String
    public var resolutionStatus: ResolutionStatus
    /// 旅行地當地時間 `HH:MM:SS`（時區見 TripDay.timeZone）。
    public var startTime: String?
    public var endTime: String?
    public var dwellMinutes: Int?
    public var fixed: Bool
    public var kind: StopKind
    public var sortOrder: Int
    public var revision: Int

    /// 只有已確認地點的 Stop 能進路線計算。
    public var isRoutable: Bool { resolutionStatus == .resolved && placeId != nil }

    enum CodingKeys: String, CodingKey {
        case id, fixed, kind, revision
        case tripId = "trip_id"
        case dayId = "day_id"
        case placeId = "place_id"
        case rawLabel = "raw_label"
        case resolutionStatus = "resolution_status"
        case startTime = "start_time"
        case endTime = "end_time"
        case dwellMinutes = "dwell_minutes"
        case sortOrder = "sort_order"
    }
}

/// `commit_itinerary` 的一筆 Stop。陣列順序即排序；帶 `id` 為更新，省略即新增，
/// 清單中沒出現的既有 Stop 會被軟刪除。
public struct StopDraft: Encodable, Equatable, Sendable {
    public var id: UUID?
    public var placeId: UUID?
    public var rawLabel: String
    /// `HH:MM`，旅行地當地時間。
    public var startTime: String?
    public var endTime: String?
    public var dwellMinutes: Int?
    public var fixed: Bool
    public var kind: StopKind

    public init(id: UUID? = nil, placeId: UUID? = nil, rawLabel: String, startTime: String? = nil,
                endTime: String? = nil, dwellMinutes: Int? = nil, fixed: Bool = false, kind: StopKind = .standard) {
        self.id = id
        self.placeId = placeId
        self.rawLabel = rawLabel
        self.startTime = startTime
        self.endTime = endTime
        self.dwellMinutes = dwellMinutes
        self.fixed = fixed
        self.kind = kind
    }

    /// 從既有 Stop 產生草稿（保留 id），用於重新排序或修改後整批提交。
    public init(_ stop: Stop) {
        self.init(id: stop.id, placeId: stop.placeId, rawLabel: stop.rawLabel,
                  startTime: stop.startTime.map(LocalTime.hourMinute), endTime: stop.endTime.map(LocalTime.hourMinute),
                  dwellMinutes: stop.dwellMinutes, fixed: stop.fixed, kind: stop.kind)
    }

    enum CodingKeys: String, CodingKey {
        case id, fixed, kind
        case placeId = "place_id"
        case rawLabel = "raw_label"
        case startTime = "start_time"
        case endTime = "end_time"
        case dwellMinutes = "dwell_minutes"
    }
}

/// 註冊 POI 用（`upsert_place`）。同一 provider id 已存在時回傳既有資料，不覆寫。
public struct PlaceDraft: Equatable, Sendable {
    public var provider: RouteProvider
    public var providerPlaceId: String
    public var name: String
    public var nameLocal: String?
    public var address: String?
    public var latitude: Double
    public var longitude: Double
    public var countryCode: String?
    public var nameZh: String?
    /// 當地文字的地址；沒有時存檔前會用當地語言反查。
    public var addressLocal: String?

    public init(provider: RouteProvider = .appleMapKit, providerPlaceId: String, name: String, nameLocal: String? = nil,
                address: String? = nil, latitude: Double, longitude: Double, countryCode: String? = nil, nameZh: String? = nil,
                addressLocal: String? = nil) {
        self.provider = provider
        self.providerPlaceId = providerPlaceId
        self.name = name
        self.nameLocal = nameLocal
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.countryCode = countryCode
        self.nameZh = nameZh
        self.addressLocal = addressLocal
    }
}

public enum LocalTime {
    /// `09:30:00` → `09:30`
    public static func hourMinute(_ time: String) -> String {
        String(time.prefix(5))
    }
}
