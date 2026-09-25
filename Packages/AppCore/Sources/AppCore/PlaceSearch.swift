import Foundation
import MapKit

/// 搜尋結果要分清楚「查無此地」與「搜尋暫時不能用」（離線、被節流）：
/// 後者不可當成「Apple 地圖沒收錄」自動處理（審查 H5）。
public enum PlaceLookup: Equatable, Sendable {
    case found([PlaceOption])
    case notFound
    case unavailable

    public var options: [PlaceOption] {
        if case .found(let options) = self { options } else { [] }
    }
}

public protocol PlaceSearching: Sendable {
    /// 回傳候選分店（最多 `limit` 筆）；找不到時回空陣列。
    func search(_ query: String, near city: String?, limit: Int) async -> [PlaceOption]
    /// 座標附近的 POI（地圖連結只有座標時使用）。
    func nearby(_ coordinate: Coordinate, limit: Int) async -> [PlaceOption]
    /// 以某個中心點附近為範圍搜尋（旅程所在城市），避免搜到其他國家的同名地點。
    func search(_ query: String, around center: Coordinate?, limit: Int) async -> [PlaceOption]
    /// 城市或島嶼的中心點（例如 "Onomichi"），找不到時為 nil。
    func locate(city: String) async -> Coordinate?
    /// 同 `search(_:around:limit:)`，但分得出查無結果與搜尋失敗。
    func lookup(_ query: String, around center: Coordinate?, limit: Int) async -> PlaceLookup
}

extension PlaceSearching {
    public func nearby(_ coordinate: Coordinate, limit: Int) async -> [PlaceOption] { [] }
    public func search(_ query: String, around center: Coordinate?, limit: Int) async -> [PlaceOption] {
        await search(query, near: nil, limit: limit)
    }
    public func locate(city: String) async -> Coordinate? { nil }
    public func lookup(_ query: String, around center: Coordinate?, limit: Int) async -> PlaceLookup {
        let options = await search(query, around: center, limit: limit)
        return options.isEmpty ? .notFound : .found(options)
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
        let items = await Self.run(request)
        return items.prefix(limit).map { PlaceOption(draft: Self.draft(from: $0)) }
    }

    public func search(_ query: String, around center: Coordinate?, limit: Int = 5) async -> [PlaceOption] {
        await lookup(query, around: center, limit: limit).options
    }

    public func lookup(_ query: String, around center: Coordinate?, limit: Int = 5) async -> PlaceLookup {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let center {
            request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                                                latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        }
        guard let items = await Self.attempt(request) else { return .unavailable }
        // 只留範圍附近（100 km 內）的結果，其他國家的同名地點不列入候選。
        let origin = center.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let options = items.filter { item in origin.map { Self.location(item).distance(from: $0) < 100_000 } ?? true }
            .prefix(limit).map { PlaceOption(draft: Self.draft(from: $0)) }
        return options.isEmpty ? .notFound : .found(Array(options))
    }

    public func locate(city: String) async -> Coordinate? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = city
        request.resultTypes = .address
        guard let item = await Self.run(request).first else { return nil }
        let c = Self.location(item).coordinate
        return Coordinate(latitude: c.latitude, longitude: c.longitude)
    }

    /// MapKit 每分鐘約 50 次查詢，超過會回 `loadingThrottled`；匯入時一次查幾十個地點很容易碰到，
    /// 所以被節流時等一下再試，不把它當成「找不到」。
    static func run(_ request: MKLocalSearch.Request) async -> [MKMapItem] {
        await attempt(request) ?? []
    }

    /// 找不到時回空陣列；網路錯誤或重試後仍被節流時回 nil（搜尋失敗，不是查無此地）。
    static func attempt(_ request: MKLocalSearch.Request) async -> [MKMapItem]? {
        for wait in [10, 20, 30, 0] {
            do {
                return try await MKLocalSearch(request: request).start().mapItems
            } catch let error as MKError where error.code == .placemarkNotFound {
                return []
            } catch let error as MKError where error.code == .loadingThrottled && wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return nil }
            } catch {
                return nil
            }
        }
        return nil
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
