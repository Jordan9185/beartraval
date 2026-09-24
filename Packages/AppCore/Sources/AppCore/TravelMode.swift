import Foundation

/// 當日交通方式。
public enum TravelMode: String, Codable, CaseIterable, Sendable {
    case walking
    case transit
    case driving
}

/// 一段路的旅行時間估算結果。
///
/// 算不出時一律是 `.unavailable`，不可用直線距離或猜測值補上（規格 §1、AC-14）。
public enum RouteEstimate: Equatable, Sendable {
    case minutes(Int, provider: RouteProvider)
    case unavailable(reason: UnavailableReason)

    public enum UnavailableReason: String, Equatable, Sendable {
        /// 供應商在該地區或模式不提供路線（例如 Apple 在韓國的大眾運輸）。
        case notSupportedInRegion
        /// 起訖點尚未確認，不得參與路線計算。
        case unconfirmedPlace
        case network
        case throttled
        case unknown
    }
}

public enum RouteProvider: String, Codable, Sendable {
    case appleMapKit = "apple_mapkit"
    case appleMapsServer = "apple_maps_server"
}
