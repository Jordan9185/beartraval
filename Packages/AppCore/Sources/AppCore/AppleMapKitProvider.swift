import Foundation
import MapKit

/// 裝置端 MapKit ETA（決策 D3）。結果以 `provider = apple_mapkit` 標記。
public struct AppleMapKitProvider: RoutingProvider {
    public let id = RouteProvider.appleMapKit

    public init() {}

    public func travelTime(from: Coordinate, to: Coordinate, mode: TravelMode, departure: Date) async -> LegTime {
        let request = MKDirections.Request()
        request.source = Self.mapItem(from)
        request.destination = Self.mapItem(to)
        request.transportType = switch mode {
        case .walking: .walking
        case .transit: .transit
        case .driving: .automobile
        }
        request.departureDate = departure
        do {
            let eta = try await MKDirections(request: request).calculateETA()
            return .minutes(eta.expectedTravelTime / 60)
        } catch {
            return .unavailable(Self.reason(error))
        }
    }

    static func mapItem(_ c: Coordinate) -> MKMapItem {
        let coordinate = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
        if #available(iOS 26, macOS 26, *) {
            return MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    }

    /// S1：「沒有路線」與「地區不支援」同為 MKError，無法區分，一律 `.unknown`。
    static func reason(_ error: any Error) -> RouteEstimate.UnavailableReason {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .network }
        if ns.domain == MKErrorDomain && ns.code == Int(MKError.Code.loadingThrottled.rawValue) { return .throttled }
        return .unknown
    }
}

extension DayPlan {
    /// 由時間軸與地點資料組出路線輸入；待確認 Stop 排除並計數。
    public static func from(_ timeline: DayTimeline, places: [UUID: Place]) -> DayPlan? {
        guard let tz = TimeZone(identifier: timeline.day.timeZone), let midnight = LocalDate.midnight(timeline.day.localDate, in: tz) else {
            return nil
        }
        var planned: [PlannedStop] = []
        var excluded = 0
        for stop in timeline.stops {
            guard stop.isRoutable, let placeID = stop.placeId, let place = places[placeID] else {
                excluded += 1
                continue
            }
            planned.append(PlannedStop(
                id: stop.id, label: place.displayTitle(fallbackChinese: stop.rawLabel),
                point: RoutePoint(coordinate: Coordinate(latitude: place.latitude, longitude: place.longitude), countryCode: place.countryCode),
                startMinutes: stop.startTime.flatMap(LocalTime.minutes), dwellMinutes: stop.dwellMinutes, fixed: stop.fixed))
        }
        return DayPlan(dayID: timeline.day.id, routeRevision: timeline.day.routeRevision, localMidnight: midnight,
                       stops: planned, excludedPendingCount: excluded, transportMode: timeline.day.transportMode)
    }
}

extension LocalDate {
    /// `yyyy-MM-dd` 在指定時區的午夜。
    public static func midnight(_ date: String, in timeZone: TimeZone) -> Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

extension LocalTime {
    /// `09:30` 或 `09:30:00` → 570
    public static func minutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":").prefix(2).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
