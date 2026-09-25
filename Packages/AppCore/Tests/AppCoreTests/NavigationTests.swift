import Foundation
import MapKit
import Testing
@testable import AppCore

struct NavigationTests {
    let tower = MapPoint(name: "N서울타워", latitude: 37.551169, longitude: 126.988227)

    @Test func appleMapsDirections() {
        let url = NavigationApp.apple.directionsURL(to: tower, mode: .transit, googleInstalled: false).absoluteString
        #expect(url.hasPrefix("https://maps.apple.com/?daddr=37.551169,126.988227"))
        #expect(url.contains("dirflg=r"))
    }

    @Test func googleMapsAppOrWeb() {
        let app = NavigationApp.google.directionsURL(to: tower, mode: .walking, googleInstalled: true).absoluteString
        #expect(app == "comgooglemaps://?daddr=37.551169,126.988227&directionsmode=walking")
        let web = NavigationApp.google.directionsURL(to: tower, mode: .driving, googleInstalled: false).absoluteString
        #expect(web == "https://www.google.com/maps/dir/?api=1&destination=37.551169,126.988227&travelmode=driving")
    }

    @Test func nearbyDistanceSaysStraightLine() {
        let option = PlaceOption(draft: PlaceDraft(providerPlaceId: "x", name: "x", latitude: 0, longitude: 0, countryCode: "KR"))
        #expect(NearbyPlace(option: option, distanceMeters: 347).distanceText == "直線 350 公尺")
        #expect(NearbyPlace(option: option, distanceMeters: 1234).distanceText == "直線 1.2 公里")
        #expect(NearbyCategory.food.savedCategory == .eat)
    }

    @Test func mapCategoryBecomesSavedCategory() {
        #expect(NearbyCategory(poi: .restaurant)?.savedCategory == .eat)
        #expect(NearbyCategory(poi: .cafe)?.savedCategory == .cafe)
        #expect(NearbyCategory(poi: .museum)?.savedCategory == .place)
        #expect(NearbyCategory(poi: .parking) == nil)
    }
}
