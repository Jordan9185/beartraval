import Foundation

/// 外開韓國在地地圖 App（Naver／Kakao）的連結產生器（§4.3.1）。
///
/// 只負責組連結；不讀回分鐘數，App 內 detour 仍顯示「無法估算」。
/// 連結格式為候選，需真機驗證（issue #1）。
public enum LocalMapApp: String, CaseIterable, Sendable {
    case naver
    case kakao

    /// `canOpenURL` 用的 scheme，需列在 `LSApplicationQueriesSchemes`。
    public var scheme: String {
        switch self {
        case .naver: "nmap"
        case .kakao: "kakaomap"
        }
    }
}

public struct MapPoint: Equatable, Sendable {
    public var name: String
    public var latitude: Double
    public var longitude: Double

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct LocalMapLink: Sendable {
    /// Naver 要求帶呼叫端的 bundle id。
    public var appName: String

    public init(appName: String) {
        self.appName = appName
    }

    /// 路線連結。`origin` 為 nil 時不帶起點，由在地 App 使用目前位置。
    public func routeURL(_ app: LocalMapApp, from origin: MapPoint?, to destination: MapPoint, mode: TravelMode) -> URL {
        switch app {
        case .naver:
            var items: [URLQueryItem] = []
            if let origin {
                items += [
                    URLQueryItem(name: "slat", value: Self.format(origin.latitude)),
                    URLQueryItem(name: "slng", value: Self.format(origin.longitude)),
                    URLQueryItem(name: "sname", value: origin.name),
                ]
            }
            items += [
                URLQueryItem(name: "dlat", value: Self.format(destination.latitude)),
                URLQueryItem(name: "dlng", value: Self.format(destination.longitude)),
                URLQueryItem(name: "dname", value: destination.name),
                URLQueryItem(name: "appname", value: appName),
            ]
            return Self.url(scheme: "nmap", host: "route", path: "/" + Self.naverMode(mode), items: items)
        case .kakao:
            var items: [URLQueryItem] = []
            if let origin {
                items.append(URLQueryItem(name: "sp", value: Self.pair(origin)))
            }
            items += [
                URLQueryItem(name: "ep", value: Self.pair(destination)),
                URLQueryItem(name: "by", value: Self.kakaoMode(mode)),
            ]
            return Self.url(scheme: "kakaomap", host: "route", path: "", items: items)
        }
    }

    /// 以店名搜尋。
    public func searchURL(_ app: LocalMapApp, query: String) -> URL {
        switch app {
        case .naver:
            Self.url(scheme: "nmap", host: "search", path: "", items: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "appname", value: appName),
            ])
        case .kakao:
            Self.url(scheme: "kakaomap", host: "search", path: "", items: [
                URLQueryItem(name: "q", value: query),
            ])
        }
    }

    /// 未安裝在地 App 時的網頁版。
    public func webFallbackURL(_ app: LocalMapApp, destination: MapPoint) -> URL {
        switch app {
        case .naver:
            // 候選：Naver 網頁版搜尋頁，待驗證。
            var components = URLComponents(string: "https://map.naver.com")!
            components.path = "/p/search/" + destination.name
            return components.url!
        case .kakao:
            // 名稱中的逗號會被當成欄位分隔，先換掉。
            let name = destination.name.replacingOccurrences(of: ",", with: " ")
            var components = URLComponents(string: "https://map.kakao.com")!
            components.path = "/link/to/\(name),\(Self.format(destination.latitude)),\(Self.format(destination.longitude))"
            return components.url!
        }
    }

    private static func naverMode(_ mode: TravelMode) -> String {
        switch mode {
        case .transit: "public"
        case .walking: "walk"
        case .driving: "car"
        }
    }

    private static func kakaoMode(_ mode: TravelMode) -> String {
        switch mode {
        case .transit: "PUBLICTRANSIT"
        case .walking: "FOOT"
        case .driving: "CAR"
        }
    }

    private static func pair(_ point: MapPoint) -> String {
        "\(format(point.latitude)),\(format(point.longitude))"
    }

    /// 固定 6 位小數（約 0.1 公尺），避免 Double 描述出現科學記號或過長尾數。
    private static func format(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func url(scheme: String, host: String, path: String, items: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = items
        return components.url!
    }
}
