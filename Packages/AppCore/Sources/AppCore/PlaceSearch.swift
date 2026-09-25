import Foundation
import MapKit

public protocol PlaceSearching: Sendable {
    /// 回傳候選分店（最多 `limit` 筆）；找不到時回空陣列。
    func search(_ query: String, near city: String?, limit: Int) async -> [PlaceOption]
    /// 座標附近的 POI（地圖連結只有座標時使用）。
    func nearby(_ coordinate: Coordinate, limit: Int) async -> [PlaceOption]
    /// 以某個中心點附近為範圍搜尋（旅程所在城市），避免搜到其他國家的同名地點。
    func search(_ query: String, around center: Coordinate?, limit: Int) async -> [PlaceOption]
}

extension PlaceSearching {
    public func nearby(_ coordinate: Coordinate, limit: Int) async -> [PlaceOption] { [] }
    public func search(_ query: String, around center: Coordinate?, limit: Int) async -> [PlaceOption] {
        await search(query, near: nil, limit: limit)
    }
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

    public func search(_ query: String, around center: Coordinate?, limit: Int = 5) async -> [PlaceOption] {
        guard let center else { return await search(query, near: nil, limit: limit) }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                                            latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return [] }
        // 只留範圍附近（100 km 內）的結果，其他國家的同名地點不列入候選。
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return items.filter { Self.location($0).distance(from: origin) < 100_000 }
            .prefix(limit).map { PlaceOption(draft: Self.draft(from: $0)) }
    }

    public func nearby(_ coordinate: Coordinate, limit: Int = 5) async -> [PlaceOption] {
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let request = MKLocalPointsOfInterestRequest(center: center, radius: 80)
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return [] }
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return items
            .sorted { Self.location($0).distance(from: origin) < Self.location($1).distance(from: origin) }
            .prefix(limit).map { PlaceOption(draft: Self.draft(from: $0)) }
    }

    static func location(_ item: MKMapItem) -> CLLocation {
        if #available(iOS 26, macOS 26, *) { return item.location }
        return item.placemark.location ?? CLLocation(latitude: 0, longitude: 0)
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
        let country = item.placemark.countryCode
        // 裝置語系為繁中時，Apple 常回傳中文譯名；依文字判斷是原文還是中文（店名保留原文並附中文）。
        let naming = PlaceNaming.classify(name: name, countryCode: country)
        return PlaceDraft(providerPlaceId: providerID(item, name: name, coordinate: coordinate), name: name, nameLocal: naming.local,
                          address: address, latitude: coordinate.latitude, longitude: coordinate.longitude, countryCode: country,
                          nameZh: naming.zh)
    }

    /// iOS 18+ 用 MapKit 的穩定 identifier；iOS 17 沒有，以名稱 + 座標（約 1 公尺）組成。
    static func providerID(_ item: MKMapItem, name: String, coordinate: CLLocationCoordinate2D) -> String {
        if #available(iOS 18, macOS 15, *), let id = item.identifier?.rawValue {
            return id
        }
        return String(format: "%@@%.5f,%.5f", name, coordinate.latitude, coordinate.longitude)
    }
}
