import AppCore
import ShareCore
import SwiftUI

/// Trip 分頁：列出自己參與的 Trip，可建立空 Trip。
struct TripListView: View {
    let session: SessionModel
    /// 旅程清單有變：要改看的旅程（nil 表示維持目前的），以及是否切到「今天」。
    var onTripsChanged: (UUID?, Bool) -> Void = { _, _ in }
    @State private var trips: [Trip] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var showsCreate = false
    @State private var showsJoin = false
    @State private var showsAccount = false
    @State private var showsInbox = false

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    ErrorText(errorMessage)
                    Button("重新載入") { Task { await reload() } }
                }
                ForEach(trips) { trip in
                    NavigationLink(value: trip) {
                        VStack(alignment: .leading) {
                            Text(trip.name)
                            Text(Self.subtitle(trip)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            .overlay {
                if !loaded {
                    ProgressView("載入中…")
                } else if trips.isEmpty && errorMessage == nil {
                    ContentUnavailableView {
                        Label("還沒有旅程", systemImage: "calendar")
                    } description: {
                        Text("自己建立一個，或用好友傳來的邀請連結加入。")
                    } actions: {
                        Button("建立旅程") { showsCreate = true }
                            .buttonStyle(.borderedProminent)
                        Button("加入好友的旅程") { showsJoin = true }
                    }
                }
            }
            .navigationTitle("旅程")
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(session: session, trip: trip) {
                    trips.removeAll { $0.id == trip.id }
                    onTripsChanged(nil, false)
                }
            }
            .toolbar {
                Button("建立旅程", systemImage: "plus") { showsCreate = true }
                Menu("更多", systemImage: "ellipsis.circle") {
                    Button("分享收件匣", systemImage: "tray") { showsInbox = true }
                    Button("加入好友的旅程", systemImage: "person.badge.plus") { showsJoin = true }
                    Button("帳號設定", systemImage: "person.crop.circle") { showsAccount = true }
                }
            }
            .sheet(isPresented: $showsAccount) { AccountView(session: session) }
            .sheet(isPresented: $showsInbox) { InboxView(session: session) }
            .onChange(of: showsInbox) { _, open in
                if !open { Task { await reload(); onTripsChanged(nil, false) } }
            }
            .sheet(isPresented: $showsJoin) {
                JoinTripView(session: session, initialToken: nil) { tripID in
                    Task { await reload() }
                    onTripsChanged(tripID, true)
                }
            }
            .sheet(isPresented: $showsCreate) {
                CreateTripView(session: session) { trip in
                    trips.insert(trip, at: 0)
                    onTripsChanged(trip.id, false)
                }
            }
            .refreshable { await reload() }
            .task { await reload() }
        }
    }

    /// 「10/23 – 10/29 · 7 天 · 首爾（UTC+9）」：與建立表單同樣的時區寫法，不露出 IANA 代碼。
    static func subtitle(_ trip: Trip) -> String {
        func short(_ date: String) -> String {
            let parts = date.split(separator: "-")
            return parts.count == 3 ? "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)" : date
        }
        var parts = ["\(short(trip.startDate)) – \(short(trip.endDate))"]
        if let tz = TimeZone(identifier: trip.timeZone),
           let start = LocalDate.midnight(trip.startDate, in: tz), let end = LocalDate.midnight(trip.endDate, in: tz) {
            parts.append("\(Int((end.timeIntervalSince(start) / 86_400).rounded()) + 1) 天")
        }
        parts.append(TripTimeZones.displayName(trip.timeZone))
        return parts.joined(separator: " · ")
    }

    private func reload() async {
        do {
            trips = try await session.trips.myTrips()
            errorMessage = nil
        } catch {
            errorMessage = "讀取失敗：\(userMessage(for: error))"
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
    @State private var endTouched = false
    @State private var timeZoneID = "Asia/Seoul"
    @State private var timeZoneTouched = false
    @State private var nameAutoFilled = false
    @State private var transportMode: TravelMode = TravelMode.suggested(forTimeZone: "Asia/Seoul")
    @State private var modeTouched = false
    @State private var rawText = ""
    @State private var importSession: ImportSession?
    @State private var errorMessage: String?
    @State private var isSaving = false

    static let timeZones = TripTimeZones.common

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("旅程名稱或一句話（例如：東京五天旅遊）", text: Binding(get: { name }, set: { name = $0; nameAutoFilled = false }))
                    DatePicker("開始", selection: $start, displayedComponents: .date)
                    DatePicker("結束", selection: Binding(get: { end }, set: { end = $0; endTouched = true }),
                               in: start..., displayedComponents: .date)
                    Picker("第一天的時區", selection: Binding(get: { timeZoneID }, set: { timeZoneID = $0; timeZoneTouched = true })) {
                        ForEach(Self.timeZones, id: \.self) { Text(TripTimeZones.displayName($0)).tag($0) }
                    }
                    Picker("主要交通方式", selection: Binding(get: { transportMode }, set: { transportMode = $0; modeTouched = true })) {
                        ForEach(TravelMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } footer: {
                    Text("跨國旅程建好後，可以在每一天的設定改時區與交通方式。韓國的大眾運輸 Apple 地圖算不出時間，建議選開車／計程車或步行。")
                }
                Section {
                    // 固定高度：長文在框內捲動，不會把上方的名稱、日期、時區擠出畫面。
                    TextEditor(text: $rawText).frame(height: 180)
                        .accessibilityLabel("行程文字")
                        .overlay(alignment: .topLeading) {
                            if rawText.isEmpty {
                                Text("貼上行程，或寫「我要去日本東京五天旅遊」").foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                } header: {
                    HStack {
                        Text("匯入行程或描述想去的地方（可略過）")
                        Spacer()
                        if hasText {
                            Button("清除") { rawText = "" }.font(.caption).textCase(nil)
                        }
                    }
                } footer: {
                    Text("已有行程會照原文整理；只有目的地與天數時，AI 會搜尋並提出可編輯的建議樣板。確認後才建立正式行程。")
                }
                if let errorMessage {
                    ErrorText(errorMessage)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: timeZoneID) { if !modeTouched { transportMode = TravelMode.suggested(forTimeZone: timeZoneID) } }
            .onChange(of: rawText) { applyIdeaDefaults() }
            .onChange(of: name) { applyIdeaDefaults() }
            .onChange(of: start) { if !endTouched { applyIdeaDates() } }
            .navigationTitle("建立旅程")
            .navigationDestination(item: $importSession) { importSession in
                ImportFlowView(session: importSession, service: session.imports, placeSearch: session.placeSearch,
                               discoveryRepository: InboxRepository(client: session.client)) { trip in
                    Task {
                        await applyMode(trip)
                        onCreated(trip)
                        dismiss()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "處理中…" : hasText ? "下一步" : "建立") { Task { await save() } }
                        .disabled(isSaving || (name.trimmingCharacters(in: .whitespaces).isEmpty
                                               && TripIdeaIntent.suggestedName(for: rawText) == nil))
                }
            }
        }
    }

    private var hasText: Bool {
        !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || TripIdeaIntent.shouldSuggest(name, tripDays: tripDays)
    }

    private var tripDays: Int {
        let calendar = Calendar.current
        return max(1, (calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                                to: calendar.startOfDay(for: max(start, end))).day ?? 0) + 1)
    }

    private var ideaInput: String {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : rawText
    }

    private func applyIdeaDefaults() {
        if !timeZoneTouched, let suggested = TripIdeaIntent.suggestedTimeZone(for: name + " " + rawText) {
            timeZoneID = suggested
        }
        applyIdeaDates()
        guard TripIdeaIntent.isRequest(ideaInput) else { return }
        if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let suggested = TripIdeaIntent.suggestedName(for: ideaInput),
           name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nameAutoFilled {
            name = suggested
            nameAutoFilled = true
        }
    }

    private func applyIdeaDates() {
        guard !endTouched, let days = TripIdeaIntent.inferredDayCount(in: ideaInput),
              let suggested = Calendar.current.date(byAdding: .day, value: days - 1, to: start) else { return }
        end = suggested
    }

    /// 新旅程每天預設大眾運輸；選了別的就整趟改掉（失敗不擋建立，之後可在旅程裡改）。
    private func applyMode(_ trip: Trip) async {
        guard transportMode != .transit else { return }
        _ = try? await session.trips.setTripTransportMode(trip.id, mode: transportMode)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // 日期選擇器的日期以裝置時區解讀，再原樣當作旅行地的當地日期。
        let device = TimeZone.current
        let importText = rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && TripIdeaIntent.shouldSuggest(name, tripDays: tripDays)
            ? name : rawText
        let tripName = TripIdeaIntent.isRequest(name) && rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TripIdeaIntent.suggestedName(for: name) ?? name.trimmingCharacters(in: .whitespaces)
            : name.trimmingCharacters(in: .whitespaces).isEmpty
                ? TripIdeaIntent.suggestedName(for: rawText) ?? "" : name.trimmingCharacters(in: .whitespaces)
        let startDate = LocalDate.string(from: start, timeZone: device)
        let suggestedEnd = !endTouched && hasText
            ? Calendar.current.date(byAdding: .day, value: (TripIdeaIntent.inferredDayCount(in: importText) ?? tripDays) - 1, to: start) : nil
        let endDate = LocalDate.string(from: max(start, suggestedEnd ?? end), timeZone: device)
        do {
            if hasText {
                importSession = try await session.imports.createImport(
                    tripName: tripName, startDate: startDate, endDate: endDate, timeZone: timeZoneID, rawText: importText)
            } else {
                let trip = try await session.trips.createTrip(name: tripName, startDate: startDate, endDate: endDate, timeZone: timeZoneID)
                await applyMode(trip)
                onCreated(trip)
                dismiss()
            }
            errorMessage = nil
        } catch {
            errorMessage = "建立失敗：\(userMessage(for: error))"
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
    @State private var showsMembers = false
    @State private var legToCompare: LegComparison?
    @State private var showsTripMode = false
    var onDeleted: () -> Void = {}
    @Environment(\.dismiss) private var dismissView

    var body: some View {
        List {
            if let errorMessage {
                ErrorText(errorMessage)
            }
            ForEach(timeline) { day in
                Section {
                    if day.stops.isEmpty {
                        Text("這天還沒有行程").foregroundStyle(.secondary)
                    }
                    ForEach(day.stops) { stop in
                        Button { selectedStop = stop } label: {
                            StopRow(stop: stop, place: stop.placeId.flatMap { places[$0] })
                        }
                        .buttonStyle(.plain)
                        if let leg = baseRoutes[day.id]?.leg(from: stop.id) {
                            // 點路段可以比較步行／大眾運輸／開車・計程車。
                            Button { legToCompare = comparison(leg, in: day) } label: {
                                LegRow(leg: leg, mode: day.day.transportMode, toName: stopName(leg.to, in: day))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // 一列說完這天的交通方式、路程與時區；可編輯時點進去改設定。
                    if myRole?.canEdit == true {
                        NavigationLink {
                            DaySettingsView(session: session, day: day, suggestion: TripTimeZones.suggested(for: day, places: places)) {
                                Task { await reload() }
                            }
                        } label: {
                            RouteStatusRow(day: day, base: baseRoutes[day.id])
                        }
                    } else {
                        RouteStatusRow(day: day, base: baseRoutes[day.id])
                    }
                    if let suggestion = TripTimeZones.mismatch(for: day, places: places) {
                        Label("這天的地點在\(TripTimeZones.displayName(suggestion))一帶，時區仍是\(TripTimeZones.displayName(day.day.timeZone))。",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("第 \(day.day.displayOrder + 1) 天 · \(day.day.localDate)")
                }
            }
        }
        .confirmationDialog("刪除「\(trip.name)」？所有旅伴都會失去這個旅程，匯入原文與 AI 紀錄也會刪除。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除旅程", role: .destructive) {
                Task {
                    do {
                        try await session.trips.deleteTrip(trip.id)
                        SnapshotCache.shared()?.remove(tripID: trip.id)
                        onDeleted()
                        dismissView()
                    } catch let e as BackendError { errorMessage = e.userMessage } catch {}
                }
            }
        }
        .sheet(item: $selectedStop) { stop in
            StopDetailView(stop: stop, place: stop.placeId.flatMap { places[$0] },
                           mode: timeline.first { $0.id == stop.dayId }?.day.transportMode ?? .transit,
                           previous: previousPlace(before: stop),
                           editing: editingContext(for: stop),
                           timeZone: timeline.first { $0.id == stop.dayId }?.day.timeZone,
                           session: session,
                           planning: timeline.first { $0.id == stop.dayId }.map { day in
                               StopPlanning(tripID: trip.id, dayID: day.id, dayTitle: "第 \(day.day.displayOrder + 1) 天") {
                                   selectedStop = nil
                                   Task { await reload() }
                               }
                           },
                           canEdit: myRole?.canEdit == true)
                .presentationDetents([.medium, .large])
        }
        .navigationTitle(trip.name)
        // toolbar 只留一個主要動作「試算順路」，其餘收進「更多」。
        .toolbar {
            Button("試算順路") { showsRouteMatch = true }
                .disabled(timeline.isEmpty)
            Menu("更多", systemImage: "ellipsis.circle") {
                Button("成員", systemImage: "person.2") { showsMembers = true }
                if myRole?.canEdit == true {
                    Button("整趟交通方式", systemImage: "car") { showsTripMode = true }
                }
                if myRole == .owner {
                    Button("刪除旅程", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
            #if DEBUG
            Menu("除錯", systemImage: "ladybug") {
                Button("寫入範例行程點到第 1 天") { Task { await seedSample() } }
            }
            #endif
        }
        .navigationDestination(isPresented: $showsMembers) { MembersView(session: session, trip: trip, myRole: myRole) }
        .sheet(item: $legToCompare) { leg in
            LegModesView(session: session, leg: leg, canEdit: myRole?.canEdit == true) { Task { await reload() } }
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("整趟旅程的交通方式", isPresented: $showsTripMode, titleVisibility: .visible) {
            ForEach(TravelMode.allCases, id: \.self) { mode in
                Button(mode.displayName) {
                    Task {
                        do {
                            try await session.trips.setTripTransportMode(trip.id, mode: mode)
                            await reload()
                        } catch { errorMessage = "更新失敗：\(userMessage(for: error))" }
                    }
                }
            }
        } message: {
            Text("每一天都改用同一種方式計算路程；之後仍可在個別日子調整。")
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

    private func comparison(_ leg: BaseRoute.Leg, in day: DayTimeline) -> LegComparison? {
        guard let fromStop = day.stops.first(where: { $0.id == leg.from }), let toStop = day.stops.first(where: { $0.id == leg.to }),
              let from = fromStop.placeId.flatMap({ places[$0] }), let to = toStop.placeId.flatMap({ places[$0] }) else { return nil }
        return LegComparison(from: from, to: to, departure: LegComparison.departure(day: day.day, from: fromStop),
                             dayID: day.id, current: day.day.transportMode)
    }

    private func editingContext(for stop: Stop) -> StopEditingContext? {
        guard myRole?.canEdit == true, let day = timeline.first(where: { $0.id == stop.dayId }) else { return nil }
        let areas = SearchAreas(places: Array(places.values), timeZones: timeline.map(\.day.timeZone),
                                preferred: day.stops.compactMap { $0.placeId.flatMap { places[$0] } })
        return StopEditingContext(session: session, day: day, searchAreas: areas) {
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
            errorMessage = "讀取失敗：\(userMessage(for: error))"
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
            errorMessage = "寫入失敗：\(userMessage(for: error))"
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
    /// Owner／Editor 才有；未定位的地點可以在這裡定位、改字或移除。
    var editing: StopEditingContext? = nil
    /// 當天時區，用來推測未定位地點在哪個國家、該開哪個當地地圖。
    var timeZone: String? = nil
    /// 有值時列出這站附近還有什麼，並可排進這天。
    var session: SessionModel? = nil
    var planning: StopPlanning? = nil
    var canEdit = false
    @Environment(\.dismiss) private var dismissDetail

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(place?.displayTitle(fallbackChinese: stop.rawLabel) ?? stop.rawLabel).font(.title3.weight(.semibold))
                    if let address = place?.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                    if let start = stop.startTime { LabeledContent("時間", value: LocalTime.hourMinute(start)) }
                    if let dwell = stop.dwellMinutes { LabeledContent("停留", value: "\(dwell) 分") }
                    if stop.fixed { Label("固定行程", systemImage: "lock.fill").foregroundStyle(.secondary) }
                    if place == nil { Text("未定位，不計入路線").font(.caption).foregroundStyle(.secondary) }
                }
                if place == nil {
                    let country = LocalMapCountry.guess(name: stop.rawLabel, timeZone: timeZone)
                    Section { TaxiCardButton(unlocatedName: stop.rawLabel, countryCode: country) }
                    Section {
                        LocalMapSearchButtons(name: stop.rawLabel, countryCode: country)
                    } header: {
                        Text("當地地圖")
                    } footer: {
                        Text("Apple 地圖沒收錄時，可以用當地地圖查看位置與營業資訊。")
                    }
                }
                if place == nil, let editing {
                    PendingStopActions(context: editing, stop: stop) { dismissDetail() }
                }
                if let place {
                    Section {
                        NavigateButton(destination: place.mapPoint, mode: mode)
                        TaxiCardButton(place: place, fallbackChineseLabel: stop.rawLabel)
                    }
                }
                if let place, place.isInKorea {
                    Section("在地地圖") {
                        LocalMapButtons(destination: place.mapPoint, origin: previous?.mapPoint, mode: mode, address: place.localAddress)
                    }
                }
                if let place, let session {
                    NearbyAroundSection(session: session, center: Coordinate(latitude: place.latitude, longitude: place.longitude),
                                        tripID: planning?.tripID, canEdit: canEdit, mode: mode, planning: planning)
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
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("固定")
                    }
                    if stop.kind == .purchase {
                        Image(systemName: "bag").font(.caption).foregroundStyle(.secondary).accessibilityLabel("購買")
                    }
                }
                if !stop.isRoutable {
                    Label("未定位，不計入路線", systemImage: "mappin.slash")
                        .font(.caption).foregroundStyle(.secondary)
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
            Text("\(day.day.transportMode.displayName) · \(summary) · \(TripTimeZones.displayName(day.day.timeZone))")
                .monospacedDigit()
            if day.pendingCount > 0 {
                Text("\(day.pendingCount) 個未定位的地點未計入")
            }
        }
        .font(.caption)
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
