import Foundation
import MapKit

/// 使用者選的導航 App（外開，App 內地圖與搜尋仍用 Apple 地圖，決策 D3）。
public enum NavigationApp: String, CaseIterable, Sendable {
    case apple
    case google

    public var displayName: String {
        switch self {
        case .apple: "Apple 地圖"
        case .google: "Google 地圖"
        }
    }

    static let key = "navigationApp"

    /// 使用者的選擇；沒選過時用 Apple 地圖。
    public static var preferred: NavigationApp {
        get { UserDefaults.standard.string(forKey: key).flatMap(NavigationApp.init(rawValue:)) ?? .apple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// 導航到目的地的連結。Google 地圖有裝 App 就開 App，否則開網頁版。
    public func directionsURL(to destination: MapPoint, mode: TravelMode, googleInstalled: Bool) -> URL {
        let pair = String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), destination.latitude, destination.longitude)
        var components: URLComponents
        switch self {
        case .apple:
            components = URLComponents(string: "https://maps.apple.com/")!
            components.queryItems = [
                URLQueryItem(name: "daddr", value: pair),
                URLQueryItem(name: "q", value: destination.name),
                URLQueryItem(name: "dirflg", value: Self.appleFlag(mode)),
            ]
        case .google where googleInstalled:
            components = URLComponents(string: "comgooglemaps://")!
            components.queryItems = [
                URLQueryItem(name: "daddr", value: pair),
                URLQueryItem(name: "directionsmode", value: Self.googleMode(mode)),
            ]
        case .google:
            components = URLComponents(string: "https://www.google.com/maps/dir/")!
            components.queryItems = [
                URLQueryItem(name: "api", value: "1"),
                URLQueryItem(name: "destination", value: pair),
                URLQueryItem(name: "travelmode", value: Self.googleMode(mode)),
            ]
        }
        return components.url!
    }

    static func appleFlag(_ mode: TravelMode) -> String {
        switch mode {
        case .walking: "w"
        case .transit: "r"
        case .driving: "d"
        }
    }

    static func googleMode(_ mode: TravelMode) -> String {
        switch mode {
        case .walking: "walking"
        case .transit: "transit"
        case .driving: "driving"
        }
    }
}

// MARK: - 附近（依目前位置，Apple 地圖 POI，依直線距離排序）

/// 附近推薦的分類。Apple 地圖沒有評分，所以只依距離排序、不標「熱門」。
public enum NearbyCategory: String, CaseIterable, Sendable {
    case sights, food, cafe, shopping

    public var title: String {
        switch self {
        case .sights: "景點"
        case .food: "美食"
        case .cafe: "咖啡"
        case .shopping: "購物"
        }
    }

    /// 收藏時用的類別（收藏與購物清單是不同清單；這裡的「購物」是地點）。
    public var savedCategory: SavedCategory {
        switch self {
        case .sights: .place
        case .food: .eat
        case .cafe: .cafe
        case .shopping: .shop
        }
    }

    var poiCategories: [MKPointOfInterestCategory] {
        switch self {
        case .sights:
            var list: [MKPointOfInterestCategory] = [.museum, .park, .nationalPark, .amusementPark, .aquarium, .zoo, .beach, .theater]
            if #available(iOS 18, macOS 15, *) { list += [.landmark, .castle, .nationalMonument] }
            return list
        case .food: return [.restaurant, .bakery, .foodMarket, .brewery, .winery]
        case .cafe: return [.cafe]
        case .shopping: return [.store, .pharmacy]
        }
    }
}

extension NearbyCategory {
    /// 地圖店家類型對應的分類；不在任何分類裡時為 nil。
    init?(poi: MKPointOfInterestCategory) {
        guard let match = Self.allCases.first(where: { $0.poiCategories.contains(poi) }) else { return nil }
        self = match
    }
}

extension MapKitPlaceSearch {
    /// 候選附上店家類型，選定後可以直接帶入收藏類別。
    static func option(from item: MKMapItem) -> PlaceOption {
        PlaceOption(draft: draft(from: item), category: item.pointOfInterestCategory.flatMap(NearbyCategory.init(poi:))?.savedCategory)
    }
}

public struct NearbyPlace: Identifiable, Equatable, Sendable {
    public var option: PlaceOption
    /// 與目前位置的直線距離（公尺）；不是路程時間。
    public var distanceMeters: Double
    public var id: String { option.id }

    public init(option: PlaceOption, distanceMeters: Double) {
        self.option = option
        self.distanceMeters = distanceMeters
    }

    /// 「直線 350 公尺」「直線 1.2 公里」：明說是直線距離，不冒充路程（規格 §1）。
    public var distanceText: String {
        distanceMeters < 1000 ? "直線 \(Int((distanceMeters / 10).rounded()) * 10) 公尺"
            : "直線 " + String(format: "%.1f", distanceMeters / 1000) + " 公里"
    }
}

extension MapKitPlaceSearch {
    /// 目前位置附近某一類的地點，依直線距離由近到遠。查不到或搜尋失敗時回空陣列。
    public func nearby(_ center: Coordinate, category: NearbyCategory, radius: Double = 800, limit: Int = 20) async -> [NearbyPlace] {
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let request = MKLocalPointsOfInterestRequest(center: origin.coordinate, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: category.poiCategories)
        let items = await Self.runPOI(request)
        return items
            .map { NearbyPlace(option: Self.option(from: $0), distanceMeters: Self.location($0).distance(from: origin)) }
            .sorted { $0.distanceMeters < $1.distanceMeters }
            .prefix(limit).map { $0 }
    }

    static func runPOI(_ request: MKLocalPointsOfInterestRequest) async -> [MKMapItem] {
        for wait in [5, 0] {
            do {
                return try await MKLocalSearch(request: request).start().mapItems
            } catch let error as MKError where error.code == .loadingThrottled && wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            } catch {
                return []
            }
        }
        return []
    }
}
