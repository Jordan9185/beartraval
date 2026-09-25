import AppCore
import MapKit
import ShareCore
import SwiftUI

/// Map（規格 §3.4）：Today Route、Saved、Food、Shopping、Other Days 圖層；與 Today 同一份資料。
struct TripMapView: View {
    let session: SessionModel
    let store: TripStore
    @State private var layers: Set<MapLayer> = Set(MapLayer.allCases)
    @State private var selected: TripMapPin?

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = store.snapshot {
                    let dayIndex = snapshot.todayIndex()
                    let pins = snapshot.pins(dayIndex: dayIndex, layers: layers)
                    Map {
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
                            MapPolyline(coordinates: route).stroke(.blue.opacity(0.5), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 4) {
                            LayerPicker(layers: $layers)
                            Text("資料版本 r\(snapshot.revision)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(.regularMaterial)
                    }
                    .sheet(item: $selected) { pin in
                        PinDetailView(session: session, snapshot: snapshot, pin: pin, dayIndex: dayIndex, canEdit: store.myRole?.canEdit == true)
                            .presentationDetents([.medium, .large])
                    }
                } else if store.loaded {
                    ContentUnavailableView("尚無已確認的地點", systemImage: "map")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("地圖")
            .navigationBarTitleDisplayModeInline()
        }
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
                Text(fixed ? "🔒" : "\(order)").font(.caption.bold()).foregroundStyle(.white)
            case .saved:
                Image(systemName: pin.layer == .food ? "fork.knife" : "bookmark.fill").font(.caption).foregroundStyle(.white)
            case .merchant:
                Image(systemName: "bag.fill").font(.caption).foregroundStyle(.white)
            }
        }
        .opacity(pin.dimmed ? 0.35 : 1)
        .accessibilityLabel(pin.title)
    }

    private var color: Color {
        switch pin.layer {
        case .todayRoute: .blue
        case .otherDays: .gray
        case .saved: .purple
        case .food: .orange
        case .shopping: .green
        }
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
                    Text(pin.title).font(.headline)
                    if let address = pin.place.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                    if case .merchant = pin.kind {
                        Text("可能販售 · 庫存未知").font(.caption).foregroundStyle(.orange)
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
