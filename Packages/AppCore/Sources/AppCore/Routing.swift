import Foundation

public struct Coordinate: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// 只用來在 Stop 很多時排序候選插入位置，**不**當作旅行時間輸出（規格 §1）。
    func straightLineMeters(to other: Coordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLng = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(other.latitude * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}

/// 一段路的查詢結果。
public enum LegTime: Equatable, Sendable {
    case minutes(Double)
    case unavailable(RouteEstimate.UnavailableReason)

    public var minutes: Double? {
        if case .minutes(let m) = self { m } else { nil }
    }
}

/// 路線供應商。MVP 只有 Apple（決策 D3）；韓國在地服務之後可接同一介面。
public protocol RoutingProvider: Sendable {
    var id: RouteProvider { get }
    func travelTime(from: Coordinate, to: Coordinate, mode: TravelMode, departure: Date) async -> LegTime
}

/// 路線上的一個點（已確認地點的 Stop 或候選地點）。
public struct RoutePoint: Hashable, Sendable {
    public var coordinate: Coordinate
    /// ISO 3166-1 alpha-2，用來套用地區規則。
    public var countryCode: String?

    public init(coordinate: Coordinate, countryCode: String?) {
        self.coordinate = coordinate
        self.countryCode = countryCode
    }

    public var isInKorea: Bool {
        if let countryCode { return countryCode.uppercased() == "KR" }
        // 國碼缺漏時以南韓範圍粗判。
        return (33.0...38.7).contains(coordinate.latitude) && (124.5...131.0).contains(coordinate.longitude)
    }
}

/// S1 實測：Apple 在韓國不提供大眾運輸，錯誤碼又和「真的沒路」相同，
/// 所以韓國 + 大眾運輸直接判定不支援，不送出請求。
public struct RegionAwareProvider: RoutingProvider {
    let base: any RoutingProvider

    public init(_ base: any RoutingProvider) {
        self.base = base
    }

    public var id: RouteProvider { base.id }

    public func travelTime(from: Coordinate, to: Coordinate, mode: TravelMode, departure: Date) async -> LegTime {
        await base.travelTime(from: from, to: to, mode: mode, departure: departure)
    }

    public func travelTime(from: RoutePoint, to: RoutePoint, mode: TravelMode, departure: Date) async -> LegTime {
        if mode == .transit && (from.isInKorea || to.isInKorea) {
            return .unavailable(.notSupportedInRegion)
        }
        return await base.travelTime(from: from.coordinate, to: to.coordinate, mode: mode, departure: departure)
    }
}

/// 旅行時間快取，鍵為 (起點, 終點, 模式, 30 分鐘時段)。unavailable 也快取，避免重複打節流中的 API。
public actor TravelTimeCache {
    struct Key: Hashable {
        let from: Coordinate
        let to: Coordinate
        let mode: TravelMode
        let slot: Int
    }

    private var entries: [Key: LegTime] = [:]
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init() {}

    static func slot(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 1800)
    }

    public func value(from: RoutePoint, to: RoutePoint, mode: TravelMode, departure: Date,
                      using provider: RegionAwareProvider) async -> LegTime {
        let key = Key(from: from.coordinate, to: to.coordinate, mode: mode, slot: Self.slot(departure))
        if let cached = entries[key] {
            hits += 1
            return cached
        }
        misses += 1
        let value = await provider.travelTime(from: from, to: to, mode: mode, departure: departure)
        // 網路錯誤與節流是暫時性的，不快取。
        if case .unavailable(let reason) = value, reason == .network || reason == .throttled {
            return value
        }
        entries[key] = value
        return value
    }
}
