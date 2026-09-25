import AppCore
import ShareCore
import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 試算順路（WP4）：搜尋候選地點，計算加到各日會多花幾分鐘。
/// 只試算、不寫入；加入行程走 proposal（WP5）。
struct RouteMatchView: View {
    let session: SessionModel
    let tripID: UUID
    let timeline: [DayTimeline]
    let places: [UUID: Place]
    /// 成功加入行程後呼叫，讓時間軸重新載入。
    let onAdded: () -> Void
    /// 從 Saved 開啟時預先帶入的候選地點。
    var preset: SearchResult? = nil
    /// Viewer 只能試算，不能加入行程（伺服器也會拒絕）。
    var canEdit = true

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var candidate: SearchResult?
    @State private var dwellMinutes = 45
    @State private var modeOverride: TravelMode?
    @State private var matches: [DayMatch] = []
    @State private var isWorking = false
    @State private var message: String?
    @State private var adding: AddRequest?

    struct AddRequest: Identifiable {
        let id = UUID()
        let dayID: UUID
        let mode: TravelMode
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("候選地點") {
                    if let candidate {
                        LabeledContent(candidate.draft.displayTitle, value: candidate.address ?? "")
                        Button("換一個") { self.candidate = nil; matches = [] }
                    } else {
                        TextField("搜尋店名或地點", text: $query)
                            .onSubmit { Task { await search() } }
                        ForEach(results) { result in
                            Button {
                                candidate = result
                                Task { await compute() }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(result.draft.displayTitle)
                                    if let address = result.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }

                Section("條件") {
                    Stepper("停留 \(dwellMinutes) 分", value: $dwellMinutes, in: 0...240, step: 15)
                    Picker("交通方式", selection: $modeOverride) {
                        Text("依各日設定").tag(TravelMode?.none)
                        ForEach(TravelMode.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                    }
                }
                .onChange(of: dwellMinutes) { Task { await compute() } }
                .onChange(of: modeOverride) { Task { await compute() } }

                if isWorking { ProgressView("計算中…") }
                if let message { Text(message).foregroundStyle(.secondary) }

                if let candidate, !matches.isEmpty {
                    if let best = RouteMatcher.bestDay(matches), let insertion = best.best {
                        Section("建議") {
                            Text("\(dayTitle(best.dayID))，\(positionText(insertion, dayID: best.dayID))")
                            MatchNumbers(insertion: insertion, stopName: stopName)
                        }
                    }
                    ForEach(matches, id: \.dayID) { match in
                        Section(dayTitle(match.dayID) + "（\(match.mode.displayName)）") {
                            DayMatchRow(match: match, candidate: candidate, previousStop: previousPoint(match),
                                        positionText: { positionText($0, dayID: match.dayID) }, stopName: stopName)
                            if match.best != nil && canEdit {
                                Button("加入這天…") { adding = AddRequest(dayID: match.dayID, mode: match.mode) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("試算順路")
            .task {
                if candidate == nil, let preset {
                    candidate = preset
                    await compute()
                }
            }
            .sheet(item: $adding) { request in
                if let candidate {
                    ProposalReviewView(session: session, tripID: tripID, dayID: request.dayID, dayTitle: dayTitle(request.dayID),
                                       mode: request.mode, candidate: candidate, dwellMinutes: dwellMinutes) {
                        adding = nil
                        onAdded()
                        dismiss()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
            }
        }
    }

    // MARK: 搜尋

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.pointOfInterest, .address]
        if let region = searchRegion { request.region = region }
        do {
            let items = try await MKLocalSearch(request: request).start().mapItems
            results = items.prefix(10).map(SearchResult.init)
            message = results.isEmpty ? "找不到符合的地點" : nil
        } catch {
            results = []
            message = "找不到符合的地點"
        }
    }

    /// 以行程中已確認地點的範圍搜尋；沒有地點時不限範圍。
    private var searchRegion: MKCoordinateRegion? {
        let lat = places.values.map(\.latitude), lng = places.values.map(\.longitude)
        guard let minLat = lat.min(), let maxLat = lat.max(), let minLng = lng.min(), let maxLng = lng.max() else { return nil }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        return MKCoordinateRegion(center: center, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
    }

    // MARK: 計算

    private func compute() async {
        guard let candidate else { return }
        isWorking = true
        defer { isWorking = false }
        let routeCandidate = RouteCandidate(point: candidate.point, dwellMinutes: dwellMinutes)
        var output: [DayMatch] = []
        for day in timeline {
            guard let plan = DayPlan.from(day, places: places) else { continue }
            output.append(await session.routes.match(routeCandidate, into: plan, mode: modeOverride ?? day.day.transportMode))
        }
        matches = output
    }

    // MARK: 顯示

    private func dayTitle(_ id: UUID) -> String {
        guard let day = timeline.first(where: { $0.id == id })?.day else { return "" }
        return "第 \(day.displayOrder + 1) 天 · \(day.localDate)"
    }

    private func stopName(_ id: UUID?) -> String? {
        guard let id, let stop = timeline.lazy.flatMap(\.stops).first(where: { $0.id == id }) else { return nil }
        if let placeID = stop.placeId, let place = places[placeID] { return place.displayTitle(fallbackChinese: stop.rawLabel) }
        return stop.rawLabel
    }

    private func positionText(_ insertion: Insertion, dayID: UUID) -> String {
        switch (stopName(insertion.previousStopID), stopName(insertion.nextStopID)) {
        case let (p?, n?): "插在「\(p)」和「\(n)」之間"
        case let (p?, nil): "排在「\(p)」之後"
        case let (nil, n?): "排在「\(n)」之前"
        default: "當天第一站"
        }
    }

    /// 外開在地地圖的起點：無法估算時沒有插入位置，依 §4.3.1 不帶起點。
    private func previousPoint(_ match: DayMatch) -> MapPoint? {
        guard let id = match.best?.previousStopID,
              let stop = timeline.lazy.flatMap(\.stops).first(where: { $0.id == id }),
              let placeID = stop.placeId, let place = places[placeID] else { return nil }
        return MapPoint(name: place.originalName, latitude: place.latitude, longitude: place.longitude)
    }
}

struct SearchResult: Identifiable, Equatable {
    let id = UUID()
    /// 加入行程時以此註冊 Place（upsert_place）。
    let draft: PlaceDraft

    init(_ item: MKMapItem) {
        draft = MapKitPlaceSearch.draft(from: item)
    }

    init(draft: PlaceDraft) {
        self.draft = draft
    }

    var name: String { draft.name }
    var address: String? { draft.address }
    var point: RoutePoint {
        RoutePoint(coordinate: Coordinate(latitude: draft.latitude, longitude: draft.longitude), countryCode: draft.countryCode)
    }

    /// 外開在地地圖用原文名稱（Naver／Kakao 以韓文搜尋較準）。
    var mapPoint: MapPoint {
        MapPoint(name: draft.nameLocal ?? draft.name, latitude: point.coordinate.latitude, longitude: point.coordinate.longitude)
    }
}

struct DayMatchRow: View {
    let match: DayMatch
    let candidate: SearchResult
    let previousStop: MapPoint?
    let positionText: (Insertion) -> String
    let stopName: (UUID?) -> String?

    var body: some View {
        switch match.result {
        case .matched(let best, _):
            Text(positionText(best))
            MatchNumbers(insertion: best, stopName: stopName)
        case .unavailable(let reason):
            Text(reason == .notSupportedInRegion
                 ? "無法估算：Apple 地圖在這個地區不提供\(match.mode.displayName)路線。可改用步行或開車試算。"
                 : "無法估算這段路線。")
                .foregroundStyle(.secondary)
        }
        if match.excludedPendingCount > 0 {
            Text("\(match.excludedPendingCount) 個待確認地點未計入").font(.caption).foregroundStyle(.secondary)
        }
        if match.best == nil && candidate.point.isInKorea {
            LocalMapButtons(destination: candidate.mapPoint, origin: previousStop, mode: match.mode, address: candidate.address)
        }
    }
}

/// 韓國地點算不出時，外開 Naver／Kakao 自行查路線（§4.3.1）。不讀回分鐘數。
struct LocalMapButtons: View {
    let destination: MapPoint
    let origin: MapPoint?
    let mode: TravelMode
    let address: String?
    @Environment(\.openURL) private var openURL

    private var link: LocalMapLink { LocalMapLink(appName: Bundle.main.bundleIdentifier ?? "beartravel") }

    var body: some View {
        Button("在 Naver 地圖查看") { open(.naver) }
        Button("在 Kakao 地圖查看") { open(.kakao) }
        Button("複製店名／地址") {
            #if canImport(UIKit)
            UIPasteboard.general.string = [destination.name, address].compactMap { $0 }.joined(separator: "\n")
            #endif
        }
    }

    private func open(_ app: LocalMapApp) {
        #if canImport(UIKit)
        let installed = UIApplication.shared.canOpenURL(URL(string: "\(app.scheme)://")!)
        #else
        let installed = false
        #endif
        openURL(installed ? link.routeURL(app, from: origin, to: destination, mode: mode) : link.webFallbackURL(app, destination: destination))
    }
}
