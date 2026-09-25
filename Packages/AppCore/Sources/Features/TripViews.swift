import AppCore
import SwiftUI

/// Trip 分頁：列出自己參與的 Trip，可建立空 Trip。
struct TripListView: View {
    let session: SessionModel
    @State private var trips: [Trip] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var showsCreate = false
    @State private var showsJoin = false

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(trips) { trip in
                    NavigationLink(value: trip) {
                        VStack(alignment: .leading) {
                            Text(trip.name).font(.headline)
                            Text("\(trip.startDate) – \(trip.endDate) · \(trip.timeZone)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if loaded && trips.isEmpty && errorMessage == nil {
                    ContentUnavailableView {
                        Label("尚未建立行程", systemImage: "calendar")
                    } actions: {
                        Button("建立旅程") { showsCreate = true }
                    }
                }
            }
            .navigationTitle("旅程")
            .navigationDestination(for: Trip.self) { TripDetailView(session: session, trip: $0) }
            .toolbar {
                Button("加入好友的旅程", systemImage: "person.badge.plus") { showsJoin = true }
                Button("建立旅程", systemImage: "plus") { showsCreate = true }
            }
            .sheet(isPresented: $showsJoin) {
                JoinTripView(session: session, initialToken: nil) { _ in Task { await reload() } }
            }
            .sheet(isPresented: $showsCreate) {
                CreateTripView(session: session) { trip in
                    trips.insert(trip, at: 0)
                }
            }
            .refreshable { await reload() }
            .task { await reload() }
        }
    }

    private func reload() async {
        do {
            trips = try await session.trips.myTrips()
            errorMessage = nil
        } catch {
            errorMessage = "讀取失敗：\(error.localizedDescription)"
        }
        loaded = true
    }
}

struct CreateTripView: View {
    let session: SessionModel
    let onCreated: (Trip) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var timeZoneID = "Asia/Seoul"
    @State private var rawText = ""
    @State private var importSession: ImportSession?
    @State private var errorMessage: String?
    @State private var isSaving = false

    static let timeZones = TripTimeZones.common

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名稱（例如：首爾 5 天）", text: $name)
                    DatePicker("開始", selection: $start, displayedComponents: .date)
                    DatePicker("結束", selection: $end, in: start..., displayedComponents: .date)
                    Picker("第一天的時區", selection: $timeZoneID) {
                        ForEach(Self.timeZones, id: \.self) { Text(TripTimeZones.displayName($0)).tag($0) }
                    }
                } footer: {
                    Text("跨國旅程建好後，可以在每一天的設定改時區。")
                }
                Section {
                    TextEditor(text: $rawText).frame(minHeight: 160)
                } header: {
                    Text("匯入行程文字（可略過）")
                } footer: {
                    Text("貼上 ChatGPT、LINE 或備忘錄的行程。解析後逐一確認地點，才會建立正式行程；原文會保留。")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("建立旅程")
            .navigationDestination(item: $importSession) { importSession in
                ImportFlowView(session: importSession, service: session.imports, placeSearch: session.placeSearch) { trip in
                    onCreated(trip)
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(hasText ? "下一步" : "建立") { Task { await save() } }
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var hasText: Bool {
        !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // 日期選擇器的日期以裝置時區解讀，再原樣當作旅行地的當地日期。
        let device = TimeZone.current
        let tripName = name.trimmingCharacters(in: .whitespaces)
        let startDate = LocalDate.string(from: start, timeZone: device)
        let endDate = LocalDate.string(from: max(start, end), timeZone: device)
        do {
            if hasText {
                importSession = try await session.imports.createImport(
                    tripName: tripName, startDate: startDate, endDate: endDate, timeZone: timeZoneID, rawText: rawText)
            } else {
                onCreated(try await session.trips.createTrip(name: tripName, startDate: startDate, endDate: endDate, timeZone: timeZoneID))
                dismiss()
            }
            errorMessage = nil
        } catch let error as BackendError {
            errorMessage = switch error {
            case .unauthenticated: "登入已失效，請重新登入。"
            case .invalid(let reason): "資料不正確（\(reason)）"
            default: "建立失敗：\(error)"
            }
        } catch {
            errorMessage = "建立失敗：\(error.localizedDescription)"
        }
    }
}

/// Trip 時間軸（唯讀）。沒有 Stop 時只顯示空狀態，不畫假的 Base Route。
struct TripDetailView: View {
    let session: SessionModel
    let trip: Trip
    @State private var timeline: [DayTimeline] = []
    @State private var places: [UUID: Place] = [:]
    @State private var baseRoutes: [UUID: BaseRoute] = [:]
    @State private var errorMessage: String?
    @State private var showsRouteMatch = false
    @State private var myRole: TripRole?
    @State private var sync: TripSync?
    @State private var selectedStop: Stop?
    @State private var revision: Int?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismissView

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(timeline) { day in
                Section {
                    if day.stops.isEmpty {
                        Label("尚無行程", systemImage: "calendar.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(day.stops) { stop in
                        Button { selectedStop = stop } label: {
                            StopRow(stop: stop, place: stop.placeId.flatMap { places[$0] })
                        }
                        .buttonStyle(.plain)
                        if let leg = baseRoutes[day.id]?.leg(from: stop.id) {
                            LegRow(leg: leg, mode: day.day.transportMode, toName: stopName(leg.to, in: day))
                        }
                    }
                    RouteStatusRow(day: day, base: baseRoutes[day.id])
                    if let suggestion = TripTimeZones.mismatch(for: day, places: places) {
                        Label("這天的地點在\(TripTimeZones.displayName(suggestion))一帶，時區仍是\(TripTimeZones.displayName(day.day.timeZone))。",
                              systemImage: "clock.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if myRole?.canEdit == true {
                        NavigationLink {
                            DaySettingsView(session: session, day: day, suggestion: TripTimeZones.suggested(for: day, places: places)) {
                                Task { await reload() }
                            }
                        } label: {
                            Label("\(day.day.transportMode.displayName) · \(TripTimeZones.displayName(day.day.timeZone))", systemImage: "gearshape")
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("第 \(day.day.displayOrder + 1) 天 · \(day.day.localDate)")
                }
            }
            if let revision {
                Section { Text("資料版本 r\(revision)").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .confirmationDialog("刪除「\(trip.name)」？所有旅伴都會失去這個旅程，匯入原文與 AI 紀錄也會刪除。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除旅程", role: .destructive) {
                Task {
                    do {
                        try await session.trips.deleteTrip(trip.id)
                        SnapshotCache.shared()?.remove(tripID: trip.id)
                        dismissView()
                    } catch let e as BackendError { errorMessage = e.userMessage } catch {}
                }
            }
        }
        .sheet(item: $selectedStop) { stop in
            StopDetailView(stop: stop, place: stop.placeId.flatMap { places[$0] },
                           mode: timeline.first { $0.id == stop.dayId }?.day.transportMode ?? .transit,
                           previous: previousPlace(before: stop),
                           editing: editingContext(for: stop))
                .presentationDetents([.medium])
        }
        .navigationTitle(trip.name)
        .toolbar {
            NavigationLink { MembersView(session: session, trip: trip, myRole: myRole) } label: { Label("成員", systemImage: "person.2") }
            if myRole == .owner {
                Menu("更多", systemImage: "ellipsis.circle") {
                    Button("刪除旅程", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
            Button("試算順路", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { showsRouteMatch = true }
                .disabled(timeline.isEmpty)
            #if DEBUG
            Menu("除錯", systemImage: "ladybug") {
                Button("寫入範例行程點到第 1 天") { Task { await seedSample() } }
            }
            #endif
        }
        .sheet(isPresented: $showsRouteMatch) {
            RouteMatchView(session: session, tripID: trip.id, timeline: timeline, places: places, onAdded: {
                Task { await reload() }
            }, canEdit: myRole?.canEdit == true)
        }
        .refreshable { await reload() }
        .task {
            myRole = try? await session.trips.myRole(in: trip.id)
            await reload()
            await startSync()
        }
        .onDisappear { Task { await sync?.stop() } }
    }

    private func stopName(_ id: UUID, in day: DayTimeline) -> String? {
        guard let stop = day.stops.first(where: { $0.id == id }) else { return nil }
        return stop.placeId.flatMap { places[$0] }?.displayTitle(fallbackChinese: stop.rawLabel) ?? stop.rawLabel
    }

    private func editingContext(for stop: Stop) -> StopEditingContext? {
        guard myRole?.canEdit == true, let day = timeline.first(where: { $0.id == stop.dayId }) else { return nil }
        return StopEditingContext(session: session, day: day, searchCenter: Coordinate.center(of: Array(places.values))) {
            selectedStop = nil
            Task { await reload() }
        }
    }

    /// 外開在地地圖時的起點：同一天前一個已確認地點的 Stop（§4.3.1）。
    private func previousPlace(before stop: Stop) -> Place? {
        guard let day = timeline.first(where: { $0.id == stop.dayId }), let i = day.stops.firstIndex(where: { $0.id == stop.id }) else { return nil }
        return day.stops[..<i].last(where: \.isRoutable)?.placeId.flatMap { places[$0] }
    }

    /// 旅伴修改行程時自動重新載入（WP7）。
    private func startSync() async {
        guard sync == nil, let revision = try? await session.trips.tripRevision(trip.id) else { return }
        let sync = TripSync(tripID: trip.id, repository: session.trips, revision: revision) { events in
            if events.contains(where: { $0.kind.hasPrefix("day.") }) { Task { await reload() } }
        }
        self.sync = sync
        await sync.start()
    }

    private func reload() async {
        do {
            async let d = session.trips.days(of: trip.id)
            async let s = session.trips.stops(of: trip.id)
            let (days, stops) = try await (d, s)
            let placeList = try await session.trips.places(ids: Array(Set(stops.compactMap(\.placeId))))
            places = Dictionary(uniqueKeysWithValues: placeList.map { ($0.id, $0) })
            timeline = DayTimeline.build(days: days, stops: stops)
            revision = try? await session.trips.tripRevision(trip.id)
            errorMessage = nil
        } catch {
            errorMessage = "讀取失敗：\(error.localizedDescription)"
            return
        }
        // Base Route 綁定當日 route_revision 與交通方式；revision 改變時重算。
        for day in timeline {
            guard let plan = DayPlan.from(day, places: places) else { continue }
            if let existing = baseRoutes[day.id], existing.routeRevision == plan.routeRevision, existing.mode == day.day.transportMode {
                continue
            }
            baseRoutes[day.id] = await session.routes.baseRoute(for: plan, mode: day.day.transportMode)
        }
    }

    #if DEBUG
    /// 走正式 RPC（upsert_place + commit_itinerary）寫入一組首爾範例，驗證時間軸顯示 DB 資料。
    private func seedSample() async {
        guard let day = timeline.first?.day else { return }
        do {
            let hotel = try await session.trips.upsertPlace(PlaceDraft(
                providerPlaceId: "debug-seed-hotel-myeongdong", name: "Nine Tree Hotel Myeongdong",
                nameLocal: "나인트리 호텔 명동", latitude: 37.5634, longitude: 126.9837, countryCode: "KR"))
            let market = try await session.trips.upsertPlace(PlaceDraft(
                providerPlaceId: "debug-seed-gwangjang", name: "Gwangjang Market", nameLocal: "광장시장",
                address: "서울특별시 종로구 창경궁로 88", latitude: 37.5700, longitude: 126.9996, countryCode: "KR"))
            let existing = timeline.first?.stops.map(StopDraft.init) ?? []
            _ = try await session.trips.commitItinerary(dayID: day.id, expectedRouteRevision: day.routeRevision, stops: existing + [
                StopDraft(placeId: hotel.id, rawLabel: "나인트리 호텔 명동 출발", startTime: "09:00", fixed: true),
                StopDraft(placeId: market.id, rawLabel: "광장시장", startTime: "10:30", dwellMinutes: 60),
                // 分店未確認：不帶 place，不參與路線。
                StopDraft(rawLabel: "聖水洞的咖啡廳（分店未定）"),
            ])
            await reload()
        } catch BackendError.staleRevision {
            errorMessage = "行程已被其他人修改，已重新載入。"
            await reload()
        } catch {
            errorMessage = "寫入失敗：\(error.localizedDescription)"
        }
    }
    #endif
}

/// Stop 詳情；韓國地點提供外開 Naver／Kakao（§4.3.1）。
struct StopDetailView: View {
    let stop: Stop
    let place: Place?
    let mode: TravelMode
    let previous: Place?
    /// Owner／Editor 才有；待確認的地點可以在這裡確認、改字或移除。
    var editing: StopEditingContext? = nil
    @Environment(\.dismiss) private var dismissDetail

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(place?.displayTitle(fallbackChinese: stop.rawLabel) ?? stop.rawLabel).font(.headline)
                    if let address = place?.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                    if let start = stop.startTime { LabeledContent("時間", value: LocalTime.hourMinute(start)) }
                    if let dwell = stop.dwellMinutes { LabeledContent("停留", value: "\(dwell) 分") }
                    LabeledContent("類型", value: stop.fixed ? "固定" : "彈性")
                    if place == nil { Text("地點待確認，不參與路線").foregroundStyle(.orange) }
                }
                if place == nil, let editing {
                    PendingStopActions(context: editing, stop: stop) { dismissDetail() }
                }
                if let place {
                    Section { TaxiCardButton(place: place, fallbackChineseLabel: stop.rawLabel) }
                }
                if let place, place.isInKorea {
                    Section("在地地圖") {
                        LocalMapButtons(destination: place.mapPoint, origin: previous?.mapPoint, mode: mode, address: place.address)
                    }
                }
            }
            .navigationTitle("行程點")
            .navigationBarTitleDisplayModeInline()
        }
    }
}

struct StopRow: View {
    let stop: Stop
    let place: Place?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(stop.startTime.map(LocalTime.hourMinute) ?? "--:--")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(stop.startTime == nil ? .tertiary : .primary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(place?.displayTitle(fallbackChinese: stop.rawLabel) ?? stop.rawLabel)
                    if stop.fixed {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange)
                            .accessibilityLabel("固定")
                    }
                    if stop.kind == .purchase {
                        Image(systemName: "bag").font(.caption2).accessibilityLabel("購買")
                    }
                }
                if !stop.isRoutable {
                    Label("地點待確認，不參與路線", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                } else if let address = place?.address {
                    Text(address).font(.caption).foregroundStyle(.secondary)
                }
                if let dwell = stop.dwellMinutes {
                    Text("停留 \(dwell) 分").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RouteStatusRow: View {
    let day: DayTimeline
    let base: BaseRoute?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent("路線（\(day.day.transportMode.displayName)）") {
                Text(summary)
            }
            if day.pendingCount > 0 {
                Text("\(day.pendingCount) 個待確認地點未計入").font(.caption)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var summary: String {
        guard let base else {
            return day.routeStatus == .notEnoughPlaces ? "尚未建立" : "計算中…"
        }
        return switch base.status {
        case .noRoute: "尚未建立"
        case .complete(let total): "全天約 \(total) 分"
        case .partial(let n): "\(n) 段無法估算"
        case .unavailable(.notSupportedInRegion): "無法估算（此地區不提供）"
        case .unavailable: "無法估算"
        }
    }
}
