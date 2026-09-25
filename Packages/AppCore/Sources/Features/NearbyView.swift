import AppCore
import CoreLocation
import ShareCore
import SwiftUI

/// 目前位置（只在使用 App 時，一次性；規格不做背景定位）。
@MainActor
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private(set) var coordinate: Coordinate?
    private(set) var status: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        #if os(iOS)
        status == .authorizedWhenInUse || status == .authorizedAlways
        #else
        status == .authorizedAlways
        #endif
    }
    var isDenied: Bool { status == .denied || status == .restricted }

    /// 要權限（第一次）或更新位置。
    func refresh() {
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isAuthorized {
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.status = status
            if self.isAuthorized { self.manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in self.coordinate = Coordinate(latitude: c.latitude, longitude: c.longitude) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}

/// 「今天」上方的附近推薦：依目前位置列出最近的幾個，點「全部」看完整清單。
struct NearbySection: View {
    let session: SessionModel
    let tripID: UUID?
    let canEdit: Bool
    let mode: TravelMode
    var planning: StopPlanning? = nil
    @State private var location = LocationProvider()
    @State private var category: NearbyCategory = .food
    @State private var places: [NearbyPlace] = []
    @State private var loading = false

    var body: some View {
        Section {
            if location.isDenied {
                Text("開啟定位才看得到附近的景點與店家。").foregroundStyle(.secondary)
                #if os(iOS)
                Button("前往設定開啟定位") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                #endif
            } else {
                Picker("分類", selection: $category) {
                    ForEach(NearbyCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if loading && places.isEmpty {
                    ProgressView("尋找附近…")
                } else if location.coordinate != nil && places.isEmpty {
                    Text("附近 800 公尺內沒有找到\(category.title)。").foregroundStyle(.secondary)
                }
                ForEach(places.prefix(3)) { place in
                    NavigationLink {
                        NearbyDetailView(session: session, place: place, category: category, tripID: tripID, canEdit: canEdit,
                                         mode: mode, planning: planning)
                    } label: { NearbyRow(place: place) }
                }
                if places.count > 3 {
                    NavigationLink("全部\(category.title)（\(places.count)）") {
                        NearbyListView(session: session, tripID: tripID, canEdit: canEdit, mode: mode,
                                       location: location, initialCategory: category, planning: planning)
                    }
                }
            }
        } header: {
            Text("你附近")
        } footer: {
            if !location.isDenied { Text("依直線距離由近到遠；Apple 地圖沒有評分資料。") }
        }
        .task { location.refresh() }
        .task(id: "\(category.rawValue)-\(location.coordinate.map { "\($0.latitude),\($0.longitude)" } ?? "")") { await load() }
    }

    private func load() async {
        guard let center = location.coordinate else { return }
        loading = true
        defer { loading = false }
        places = await MapKitPlaceSearch().nearby(center, category: category)
    }
}

struct NearbyRow: View {
    let place: NearbyPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(place.option.displayTitle)
            Text(place.distanceText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}

/// 附近的完整清單（四個分類切換）。
struct NearbyListView: View {
    let session: SessionModel
    let tripID: UUID?
    let canEdit: Bool
    let mode: TravelMode
    let location: LocationProvider
    let initialCategory: NearbyCategory
    var planning: StopPlanning? = nil
    @State private var category: NearbyCategory?
    @State private var places: [NearbyPlace] = []
    @State private var loading = false

    private var current: NearbyCategory { category ?? initialCategory }

    var body: some View {
        List {
            Picker("分類", selection: Binding(get: { current }, set: { category = $0 })) {
                ForEach(NearbyCategory.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if loading && places.isEmpty { ProgressView("尋找附近…") }
            ForEach(places) { place in
                NavigationLink {
                    NearbyDetailView(session: session, place: place, category: current, tripID: tripID, canEdit: canEdit,
                                     mode: mode, planning: planning)
                } label: { NearbyRow(place: place) }
            }
        }
        .navigationTitle("你附近")
        .navigationBarTitleDisplayModeInline()
        .refreshable { location.refresh(); await load() }
        .task(id: current) { await load() }
    }

    private func load() async {
        guard let center = location.coordinate else { return }
        loading = true
        defer { loading = false }
        places = await MapKitPlaceSearch().nearby(center, category: current)
    }
}

/// 可以把附近的地點排進哪一天（走 proposal，使用者看過路程再確認；規格 §1）。
struct StopPlanning {
    let tripID: UUID
    let dayID: UUID
    let dayTitle: String
    let onAdded: () -> Void
}

/// 某個行程點附近還有什麼：依與這站的直線距離列出，可點進去排進這天。
struct NearbyAroundSection: View {
    let session: SessionModel
    let center: Coordinate
    let tripID: UUID?
    let canEdit: Bool
    let mode: TravelMode
    let planning: StopPlanning?
    @State private var category: NearbyCategory = .sights
    @State private var places: [NearbyPlace] = []
    @State private var loading = false

    var body: some View {
        Section {
            Picker("分類", selection: $category) {
                ForEach(NearbyCategory.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if loading && places.isEmpty { ProgressView("尋找附近…") }
            else if places.isEmpty {
                Text("這站 \(category == .sights ? "1 公里" : "600 公尺")內沒有找到\(category.title)。").foregroundStyle(.secondary)
            }
            ForEach(places.prefix(6)) { place in
                NavigationLink {
                    NearbyDetailView(session: session, place: place, category: category, tripID: tripID, canEdit: canEdit,
                                     mode: mode, planning: planning)
                } label: { NearbyRow(place: place) }
            }
        } header: {
            Text("這附近還有")
        } footer: {
            Text("依與這站的直線距離排序。點進去可以看加入後多花幾分鐘，再決定要不要排進這天。")
        }
        .task(id: category) {
            loading = true
            defer { loading = false }
            // 排除這站本身（距離幾公尺內的同一個地點）。
            places = await MapKitPlaceSearch().nearby(center, category: category, radius: category == .sights ? 1000 : 600)
                .filter { $0.distanceMeters > 20 }
        }
    }
}

/// 附近地點的詳情：排進行程、收藏、導航、給司機看、當地地圖。收藏只進共同收藏清單，不改正式行程。
struct NearbyDetailView: View {
    let session: SessionModel
    let place: NearbyPlace
    let category: NearbyCategory
    let tripID: UUID?
    let canEdit: Bool
    let mode: TravelMode
    var planning: StopPlanning? = nil
    @State private var saved = false
    @State private var saving = false
    @State private var errorMessage: String?

    private var draft: PlaceDraft { place.option.draft }
    private var point: MapPoint { MapPoint(name: draft.nameLocal ?? draft.name, latitude: draft.latitude, longitude: draft.longitude) }
    private var inKorea: Bool { draft.countryCode?.uppercased() == "KR" }

    var body: some View {
        Form {
                Section {
                    Text(place.option.displayTitle).font(.title3.weight(.semibold))
                    if let address = draft.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                    Text(place.distanceText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let planning, canEdit {
                    Section {
                        NavigationLink {
                            ProposalReviewView(session: session, tripID: planning.tripID, dayID: planning.dayID, dayTitle: planning.dayTitle,
                                               mode: mode, candidate: SearchResult(draft: draft),
                                               dwellMinutes: category.savedCategory.defaultDwellMinutes, embedded: true,
                                               onAdded: planning.onAdded)
                        } label: {
                            Label("排進\(planning.dayTitle)", systemImage: "calendar.badge.plus")
                        }
                    } footer: {
                        Text("先算出加入後多花幾分鐘、會不會影響固定行程，確認後才會加入。")
                    }
                }
                Section {
                    if let tripID, canEdit {
                        Button(saved ? "已加入收藏" : saving ? "收藏中…" : "加入收藏", systemImage: saved ? "checkmark.circle.fill" : "bookmark") {
                            Task { await save(tripID) }
                        }
                        .disabled(saved || saving)
                    }
                    NavigateButton(destination: point, mode: mode)
                    TaxiCardButton(place: Place(id: UUID(), provider: draft.provider.rawValue, providerPlaceId: draft.providerPlaceId,
                                                name: draft.name, nameLocal: draft.nameLocal, address: draft.address,
                                                latitude: draft.latitude, longitude: draft.longitude, countryCode: draft.countryCode,
                                                nameZh: draft.nameZh))
                }
                if inKorea {
                    Section("在地地圖") {
                        LocalMapButtons(destination: point, origin: nil, mode: mode, address: draft.address)
                    }
                }
                if let errorMessage { ErrorText(errorMessage) }
        }
        .navigationTitle("附近地點")
        .navigationBarTitleDisplayModeInline()
    }

    private func save(_ tripID: UUID) async {
        saving = true
        defer { saving = false }
        do {
            let stored = try await session.trips.upsertPlace(draft)
            _ = try await session.trips.savePlace(tripID: tripID, label: draft.name, category: category.savedCategory,
                                                  placeID: stored.id, source: nil)
            saved = true
            errorMessage = nil
        } catch {
            errorMessage = "收藏失敗：\(userMessage(for: error))"
        }
    }
}

/// 「用 Apple 地圖／Google 地圖導航」：依帳號設定裡選的導航 App 外開。
struct NavigateButton: View {
    let destination: MapPoint
    let mode: TravelMode
    @AppStorage("navigationApp") private var app: String = NavigationApp.apple.rawValue
    @Environment(\.openURL) private var openURL

    private var choice: NavigationApp { NavigationApp(rawValue: app) ?? .apple }

    var body: some View {
        Button("用\(choice.displayName)導航", systemImage: "arrow.triangle.turn.up.right.diamond") {
            openURL(choice.directionsURL(to: destination, mode: mode, googleInstalled: googleInstalled))
        }
    }

    private var googleInstalled: Bool {
        #if canImport(UIKit)
        UIApplication.shared.canOpenURL(URL(string: "comgooglemaps://")!)
        #else
        false
        #endif
    }
}
