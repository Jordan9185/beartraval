import AppCore
import ShareCore
import SwiftUI

/// Today（規格 §3.2）：今日行程摘要、順路 Saved、今日可買、購物進度。
struct TodayView: View {
    let session: SessionModel
    let store: TripStore
    let onDebug: (() -> Void)?
    /// 還沒有旅程時，帶使用者到「旅程」分頁。
    var goToTrips: () -> Void = {}

    @State private var dayIndex: Int?
    @State private var nearby: [(SavedEntry, DayMatch)] = []
    @State private var computingNearby = false
    @State private var adding: SavedEntry?
    @State private var showsAssistant = false
    @State private var showsAccount = false
    @State private var selectedStop: Stop?
    @State private var todayBase: BaseRoute?

    /// 順路門檻：加入後多花不超過此分鐘數才算「順路」。
    static let nearbyThresholdMinutes = 20

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = store.snapshot, let index = dayIndex ?? Optional(snapshot.todayIndex()),
                   snapshot.timeline.indices.contains(index) {
                    content(snapshot, index)
                } else if store.loaded && store.snapshot == nil {
                    ContentUnavailableView {
                        Label("尚未建立旅程", systemImage: "sun.max")
                    } actions: {
                        Button("建立旅程", action: goToTrips).buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("今天")
            .toolbar {
                if store.trips.count > 1 {
                    Picker("旅程", selection: Binding(get: { store.selectedTripID }, set: { store.selectedTripID = $0 })) {
                        ForEach(store.trips) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Button("設定", systemImage: "person.crop.circle") { showsAccount = true }
                if store.snapshot != nil {
                    Button("AI 助手", systemImage: "sparkles") { showsAssistant = true }
                }
                if let onDebug { Button("除錯", systemImage: "ladybug", action: onDebug) }
            }
            .sheet(isPresented: $showsAccount) { AccountView(session: session) }
            .sheet(isPresented: $showsAssistant) {
                if let snapshot = store.snapshot {
                    AssistantView(session: session, snapshot: snapshot, canApply: store.myRole?.canEdit == true) {
                        Task { await store.reload() }
                    }
                }
            }
            .refreshable { await store.reload() }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: TripSnapshot, _ index: Int) -> some View {
        let day = snapshot.timeline[index]
        List {
            Section {
                HStack {
                    Button { dayIndex = index - 1 } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                    Spacer()
                    VStack {
                        Text(snapshot.trip.name).font(.headline)
                        Text("第 \(index + 1) 天 · \(day.day.localDate)").font(.subheadline).foregroundStyle(.secondary)
                        Text(TripTimeZones.displayName(day.day.timeZone) + "時間").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { dayIndex = index + 1 } label: { Image(systemName: "chevron.right") }.disabled(index >= snapshot.timeline.count - 1)
                }
                .buttonStyle(.borderless)
            }

            Section {
                if day.stops.isEmpty {
                    Text("今天沒有行程").foregroundStyle(.secondary)
                }
                ForEach(day.stops) { stop in
                    Button { selectedStop = stop } label: { HStack {
                        Text(stop.startTime.map(LocalTime.hourMinute) ?? "--:--").monospacedDigit().foregroundStyle(.secondary)
                        Text(stop.placeId.flatMap { snapshot.places[$0] }.map { $0.displayTitle(fallbackChinese: stop.rawLabel) } ?? stop.rawLabel)
                        if stop.fixed { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel("固定") }
                        if stop.kind == .purchase { Image(systemName: "bag").font(.caption) }
                    } }
                    .buttonStyle(.plain)
                    if let leg = todayBase?.dayID == day.id ? todayBase?.leg(from: stop.id) : nil {
                        LegRow(leg: leg, mode: day.day.transportMode, toName: nil)
                    }
                }
                NavigationLink("完整行程") { TripDetailView(session: session, trip: snapshot.trip) }
            } header: {
                Text("今日行程")
            }

            Section {
                if computingNearby { ProgressView("計算順路…") }
                else if nearby.isEmpty { Text("沒有順路的收藏").foregroundStyle(.secondary) }
                ForEach(nearby, id: \.0.id) { entry, match in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.title)
                            Text("+\(match.best?.addedTravelMinutes ?? 0) 分路程 · \(entry.saved.category.displayName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.myRole?.canEdit == true { Button("加入") { adding = entry }.buttonStyle(.borderless) }
                    }
                }
            } header: {
                Text("順路收藏（\(nearby.count)）")
            } footer: {
                Text("加入後多花 \(Self.nearbyThresholdMinutes) 分鐘以內的收藏。")
            }

            let todayItems = snapshot.todayShopping(dayIndex: index)
            Section {
                if todayItems.isEmpty { Text("今天沒有安排要買的東西").foregroundStyle(.secondary) }
                ForEach(todayItems) { entry in
                    HStack {
                        Text(entry.item.name)
                        Spacer()
                        Text(entry.plannedStore ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                let progress = snapshot.shoppingProgress
                if progress.total > 0 { LabeledContent("已買", value: "\(progress.purchased)／\(progress.total)") }
            } header: {
                Text("今天可買")
            }

            Section {
                if let cachedAt = store.cachedAt {
                    Label("離線資料：\(cachedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "icloud.slash")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("資料版本 r\(snapshot.revision)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .task(id: "\(snapshot.revision)-\(index)") { await computeNearby(snapshot, index) }
        .sheet(item: $selectedStop) { stop in
            StopDetailView(stop: stop, place: stop.placeId.flatMap { snapshot.places[$0] }, mode: day.day.transportMode,
                           previous: day.stops.prefix { $0.id != stop.id }.last(where: \.isRoutable)?.placeId.flatMap { snapshot.places[$0] },
                           editing: store.myRole?.canEdit == true ? StopEditingContext(session: session, day: day,
                                                                                       searchAreas: SearchAreas(places: Array(snapshot.places.values),
                                                                                                                timeZones: snapshot.timeline.map(\.day.timeZone),
                                                                                                                preferred: day.stops.compactMap { $0.placeId.flatMap { snapshot.places[$0] } })) {
                               selectedStop = nil
                               Task { await store.reload() }
                           } : nil,
                           timeZone: day.day.timeZone)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $adding) { entry in
            if let place = entry.place {
                ProposalReviewView(session: session, tripID: snapshot.trip.id, dayID: day.day.id, dayTitle: "第 \(index + 1) 天",
                                   mode: day.day.transportMode, candidate: SearchResult(draft: place.asDraft),
                                   dwellMinutes: entry.saved.category.defaultDwellMinutes) {
                    adding = nil
                    Task { await store.reload() }
                }
            }
        }
    }

    private func computeNearby(_ snapshot: TripSnapshot, _ index: Int) async {
        guard let plan = DayPlan.from(snapshot.timeline[index], places: snapshot.places), !plan.stops.isEmpty else {
            nearby = []
            todayBase = nil
            return
        }
        todayBase = await session.routes.baseRoute(for: plan, mode: snapshot.timeline[index].day.transportMode)
        computingNearby = true
        defer { computingNearby = false }
        var result: [(SavedEntry, DayMatch)] = []
        for entry in snapshot.routableSaved.prefix(10) {
            guard let place = entry.place else { continue }
            let point = RoutePoint(coordinate: Coordinate(latitude: place.latitude, longitude: place.longitude), countryCode: place.countryCode)
            let match = await session.routes.match(RouteCandidate(point: point, dwellMinutes: entry.saved.category.defaultDwellMinutes),
                                                   into: plan, mode: snapshot.timeline[index].day.transportMode)
            if let minutes = match.best?.addedTravelMinutes, minutes <= Self.nearbyThresholdMinutes { result.append((entry, match)) }
        }
        nearby = result.sorted { ($0.1.best?.addedTravelMinutes ?? 0) < ($1.1.best?.addedTravelMinutes ?? 0) }
    }
}

extension Place {
    var asDraft: PlaceDraft {
        PlaceDraft(providerPlaceId: providerPlaceId, name: name, nameLocal: nameLocal, address: address,
                   latitude: latitude, longitude: longitude, countryCode: countryCode, nameZh: nameZh)
    }

    var mapPoint: MapPoint {
        MapPoint(name: originalName, latitude: latitude, longitude: longitude)
    }

    var isInKorea: Bool {
        RoutePoint(coordinate: Coordinate(latitude: latitude, longitude: longitude), countryCode: countryCode).isInKorea
    }
}
