import AppCore
import MapKit
import ShareCore
import SwiftUI

/// Map（規格 §3.4）：Today Route、Saved、Food、Shopping、Other Days 圖層；與 Today 同一份資料。
struct TripMapView: View {
    let session: SessionModel
    let store: TripStore
    var goToTrips: () -> Void = {}
    @State private var layers: Set<MapLayer> = Set(MapLayer.allCases)
    @State private var selected: TripMapPin?
    @State private var position: MapCameraPosition = .automatic
    @State private var framedRevision: Int?
    private let locationManager = CLLocationManager()

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = store.snapshot {
                    let dayIndex = snapshot.todayIndex()
                    let pins = snapshot.pins(dayIndex: dayIndex, layers: layers)
                    Map(position: $position) {
                        UserAnnotation()
                        ForEach(pins) { pin in
                            Annotation(pin.title, coordinate: CLLocationCoordinate2D(latitude: pin.place.latitude, longitude: pin.place.longitude)) {
                                Button { selected = pin } label: { PinMarker(pin: pin) }
                            }
                        }
                        // 只標示順序，不是實際路線（路線時間見 Trip 頁）。
                        let route = pins.filter { $0.layer == .todayRoute }.map {
                            CLLocationCoordinate2D(latitude: $0.place.latitude, longitude: $0.place.longitude)
                        }
                        if route.count > 1 {
                            MapPolyline(coordinates: route).stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
                        }
                    }
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                        MapScaleView()
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("今天的行程", systemImage: "scope") { position = Self.frame(pins) }
                                .accessibilityIdentifier("frameToday")
                        }
                    }
                    // 開啟時只框今天的行程（其他天與其他國家的圖釘不算），不要一打開就縮到整個東北亞。
                    .onAppear {
                        guard framedRevision != snapshot.revision else { return }
                        framedRevision = snapshot.revision
                        position = Self.frame(pins)
                        if locationManager.authorizationStatus == .notDetermined {
                            locationManager.requestWhenInUseAuthorization()
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        LayerPicker(layers: $layers)
                        .padding(8)
                        .background(.regularMaterial)
                    }
                    .sheet(item: $selected) { pin in
                        PinDetailView(session: session, snapshot: snapshot, pin: pin, dayIndex: dayIndex, canEdit: store.myRole?.canEdit == true)
                            .presentationDetents([.medium, .large])
                    }
                } else if store.loaded {
                    ContentUnavailableView {
                        Label("尚未建立旅程", systemImage: "map")
                    } actions: {
                        Button("建立旅程", action: goToTrips).buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("地圖")
            .navigationBarTitleDisplayModeInline()
        }
    }
}

extension TripMapView {
    /// 今天行程的範圍；今天沒有已定位地點時，框圖釘最多的區域。
    static func frame(_ pins: [TripMapPin]) -> MapCameraPosition {
        let today = pins.filter { $0.layer == .todayRoute }.map(\.place)
        let places = today.isEmpty ? pins.map(\.place) : today
        guard let center = SearchAreas(places: places).centers.first else { return .automatic }
        let nearby = places.filter {
            SearchAreas.distanceKm(center, Coordinate(latitude: $0.latitude, longitude: $0.longitude)) < 150
        }
        let lats = nearby.map(\.latitude), lngs = nearby.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLng = lngs.min(), let maxLng = lngs.max() else { return .automatic }
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, (maxLat - minLat) * 1.4), longitudeDelta: max(0.01, (maxLng - minLng) * 1.4))
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2), span: span))
    }
}

extension View {
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

struct PinMarker: View {
    let pin: TripMapPin

    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: 28, height: 28)
            switch pin.kind {
            case .stop(_, let order, let fixed):
                Group { if fixed { Image(systemName: "lock.fill") } else { Text("\(order)") } }.font(.caption.bold()).foregroundStyle(.white)
            case .saved:
                Image(systemName: pin.layer == .food ? "fork.knife" : "bookmark.fill").font(.caption).foregroundStyle(.white)
            case .merchant:
                Image(systemName: "bag.fill").font(.caption).foregroundStyle(.white)
            }
        }
        .opacity(pin.dimmed ? 0.35 : 1)
        .accessibilityLabel(pin.title)
    }

    /// 只用兩色：今日路線用主色，其他圖層灰色；圖層差別由圖示表達（樣式指南）。
    private var color: Color {
        pin.layer == .todayRoute ? .accentColor : Color(white: 0.55)
    }
}

struct LayerPicker: View {
    @Binding var layers: Set<MapLayer>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(MapLayer.allCases, id: \.self) { layer in
                    Button(layer.title) {
                        if layers.contains(layer) { layers.remove(layer) } else { layers.insert(layer) }
                    }
                    .buttonStyle(.bordered)
                    .tint(layers.contains(layer) ? .accentColor : .gray)
                    .font(.caption)
                }
            }
        }
    }
}

/// Pin 詳情：地點資訊、Route Match；韓國地點可外開 Naver／Kakao（§4.3.1）。
struct PinDetailView: View {
    let session: SessionModel
    let snapshot: TripSnapshot
    let pin: TripMapPin
    let dayIndex: Int
    let canEdit: Bool
    @State private var showsRoute = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(pin.title).font(.title3.weight(.semibold))
                    if let address = pin.place.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                    if case .merchant = pin.kind {
                        Text("可能販售 · 庫存未知").font(.caption).foregroundStyle(.secondary)
                        if pin.dimmed { Text("這個商品已購買").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    TaxiCardButton(place: pin.place)
                    if case .stop = pin.kind {} else { Button("試算順路") { showsRoute = true } }
                }
                if pin.place.isInKorea {
                    Section("在地地圖") {
                        LocalMapButtons(destination: pin.place.mapPoint, origin: nil,
                                        mode: snapshot.timeline[safe: dayIndex]?.day.transportMode ?? .transit, address: pin.place.address)
                    }
                }
            }
            .navigationTitle(pin.layer.title)
            .navigationBarTitleDisplayModeInline()
            .sheet(isPresented: $showsRoute) {
                RouteMatchView(session: session, tripID: snapshot.trip.id, timeline: snapshot.timeline, places: snapshot.places,
                               onAdded: {}, preset: SearchResult(draft: pin.place.asDraft), canEdit: canEdit)
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
