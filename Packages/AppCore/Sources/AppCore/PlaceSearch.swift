import Foundation
import MapKit

public protocol PlaceSearching: Sendable {
    /// 回傳候選分店（最多 `limit` 筆）；找不到時回空陣列。
    func search(_ query: String, near city: String?, limit: Int) async -> [PlaceOption]
}

/// Apple MapKit POI 搜尋（決策 D3）。
public struct MapKitPlaceSearch: PlaceSearching {
    public init() {}

    public func search(_ query: String, near city: String?, limit: Int = 5) async -> [PlaceOption] {
        let request = MKLocalSearch.Request()
        // S1：搜尋結果依查詢字串而定，把城市併入查詢比 region 更穩定。
        request.naturalLanguageQuery = [query, city].compactMap { $0 }.joined(separator: " ")
        request.resultTypes = [.pointOfInterest, .address]
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return [] }
        return items.prefix(limit).map { PlaceOption(draft: Self.draft(from: $0)) }
    }

    public static func draft(from item: MKMapItem) -> PlaceDraft {
        let coordinate: CLLocationCoordinate2D
        let address: String?
        if #available(iOS 26, macOS 26, *) {
            coordinate = item.location.coordinate
            address = item.address?.fullAddress.replacingOccurrences(of: "\n", with: " ")
        } else {
            coordinate = item.placemark.coordinate
            address = item.placemark.title
        }
        let name = item.name ?? "（未命名）"
        return PlaceDraft(providerPlaceId: providerID(item, name: name, coordinate: coordinate), name: name, address: address,
                          latitude: coordinate.latitude, longitude: coordinate.longitude, countryCode: item.placemark.countryCode)
    }

    /// iOS 18+ 用 MapKit 的穩定 identifier；iOS 17 沒有，以名稱 + 座標（約 1 公尺）組成。
    static func providerID(_ item: MKMapItem, name: String, coordinate: CLLocationCoordinate2D) -> String {
        if #available(iOS 18, macOS 15, *), let id = item.identifier?.rawValue {
            return id
        }
        return String(format: "%@@%.5f,%.5f", name, coordinate.latitude, coordinate.longitude)
    }
}
