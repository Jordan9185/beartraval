import MapKit
import Testing
@testable import AppCore

struct PlaceKeyTests {
    @Test func fallbackIDNeverUsesServerReservedTilde() {
        let coordinate = CLLocationCoordinate2D(latitude: 37.5, longitude: 127)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        let id = MapKitPlaceSearch.providerID(item, name: "Café~Bar", coordinate: coordinate)
        #expect(id == "Café-Bar@37.50000,127.00000")
        #expect(!id.contains("~"))
    }
}
