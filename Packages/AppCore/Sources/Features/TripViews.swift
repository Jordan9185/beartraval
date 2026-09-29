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
    @State private var showsAIActivity = false
    @State private var showsInbox = false
    @State private var showsCapture = false
    @State private var captured = false
    @State private var archivedIDs: Set<UUID> = []
    @State private var viewingArchive = false
    @State private var catalogCachedAt: Date?

    var body: some View {
        NavigationStack {
            List {
                if let message = session.discoveryError { ErrorText(message) }
                if let errorMessage {
                    ErrorText(errorMessage)
                    Button("重新載入") { Task { await reload() } }
                }
                if let catalogCachedAt {
                    Text("顯示 \(catalogCachedAt.formatted(date: .abbreviated, time: .shortened)) 保存的清單；封存與恢復需連線。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(trips.filter { archivedIDs.contains($0.id) == viewingArchive }) { trip in
                    NavigationLink(value: trip) {
                        VStack(alignment: .leading) {
                            Text(trip.name)
                            Text(Self.subtitle(trip)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .swipeActions {
                        Button(viewingArchive ? "恢復旅程" : "封存") {
                            Task {
                                do {
                                    try await session.trips.setTripArchived(trip.id, archived: !viewingArchive)
                                    await reload()
                                    onTripsChanged(nil, false)
                                } catch { errorMessage = userMessage(for: error) }
                            }
                        }.tint(.gray).disabled(catalogCachedAt != nil)
                    }
                }
            }
            .overlay {
                if !loaded {
                    ProgressView("載入中…")
                } else if viewingArchive && !trips.contains(where: { archivedIDs.contains($0.id) }) && errorMessage == nil {
                    ContentUnavailableView("沒有封存旅程", systemImage: "archivebox", description: Text("旅程不會自動封存；在旅程列向左滑動可手動封存。"))
                } else if !viewingArchive && !trips.contains(where: { !archivedIDs.contains($0.id) }) && errorMessage == nil {
                    ContentUnavailableView {
                        Label("還沒有旅程", systemImage: "calendar")
                    } description: {
                        Text("先把旅行資料交給 AI 整理，想好再建立旅程；也可以加入好友的旅程。")
                    } actions: {
                        Button("交給 AI 整理") { showsCapture = true }
                            .buttonStyle(.borderedProminent)
                        Button("建立旅程") { showsCreate = true }
                        Button("加入好友的旅程") { showsJoin = true }
                    }
                }
            }
            .navigationTitle(viewingArchive ? "已封存旅程" : "旅程")
            .onChange(of: session.aiActivity.completionVersion) { Task { await reload() } }
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(session: session, trip: trip, isArchived: archivedIDs.contains(trip.id)) {
                    trips.removeAll { $0.id == trip.id }
                    onTripsChanged(nil, false)
                }
                .onAppear { if !viewingArchive { onTripsChanged(trip.id, false) } }
            }
            .toolbar {
                if viewingArchive {
                    // 封存清單與旅程列表同一層，需要明顯的返回入口，不只藏在選單裡。
                    ToolbarItem(placement: .navigation) {
                        Button("返回旅程", systemImage: "chevron.backward") { viewingArchive = false }
                            .accessibilityIdentifier("leaveArchive")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("交給 AI 整理", systemImage: "tray.and.arrow.down") { showsCapture = true }
                }
                ToolbarItem(placement: .primaryAction) {
                Menu("更多", systemImage: "ellipsis.circle") {
                    Button(viewingArchive ? "返回旅程" : "已封存旅程", systemImage: "archivebox") { viewingArchive.toggle() }
                    Button("AI 進度", systemImage: "clock") { showsAIActivity = true }
                    Button("建立旅程", systemImage: "plus") { showsCreate = true }
                    Button("分享收件匣", systemImage: "tray") { showsInbox = true }
                    Button("加入好友的旅程", systemImage: "person.badge.plus") { showsJoin = true }
                    Button("帳號設定", systemImage: "person.crop.circle") { showsAccount = true }
                }
                }
            }
            .sheet(isPresented: $showsCapture, onDismiss: {
                if captured { captured = false; showsInbox = true }
            }) {
                InboxComposeView(ownerHint: session.trips.currentUserID) {
                    captured = true
                    Task { await session.syncInboxCaptures() }
                }
            }
            .sheet(isPresented: $showsAccount) { AccountView(session: session) }
            .sheet(isPresented: $showsAIActivity) { AIActivityView(monitor: session.aiActivity) }
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
                    onTripsChanged(trip.id, true)
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
            let freshTrips = try await session.trips.allTrips()
            let freshArchives = try await session.trips.archivedTripIDs()
            trips = freshTrips; archivedIDs = freshArchives; catalogCachedAt = nil
            if let owner = session.trips.currentUserID {
                try? TripCatalogCache.shared(owner: owner)?.save(.init(trips: trips, archivedIDs: archivedIDs))
            }
            errorMessage = nil
        } catch {
            if case .other = BackendError.from(error), let owner = session.trips.currentUserID,
               let cache = TripCatalogCache.shared(owner: owner)?.load() {
                trips = cache.trips; archivedIDs = cache.archivedIDs; catalogCachedAt = cache.savedAt
            } else {
                trips = []; archivedIDs = []; catalogCachedAt = nil
                if let owner = session.trips.currentUserID { TripCatalogCache.shared(owner: owner)?.remove() }
            }
            errorMessage = "讀取失敗：\(userMessage(for: error))"
        }
        loaded = true
    }
}

struct CreateTripView: View {
    let session: SessionModel
    let onCreated: (Trip) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var restoringDraft = true
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
    @State private var prepared = false
    @State private var preparing = false
    @State private var summary: String?
    @State private var datesConfirmed = false
    private struct FormDraft: Codable {
        var rawText: String; var name: String; var start: Date; var end: Date; var timeZone: String
        var mode: TravelMode; var prepared: Bool; var datesConfirmed: Bool; var summary: String?; var importID: UUID?
    }
    private var formDraft: FormDraft { FormDraft(rawText: rawText, name: name, start: start, end: end, timeZone: timeZoneID,
        mode: transportMode, prepared: prepared, datesConfirmed: datesConfirmed, summary: summary, importID: importSession?.id) }
    private var draftKey: String { "trip-create-" + (session.trips.currentUserID?.uuidString ?? "unsigned") }

    static let timeZones = TripTimeZones.common

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // 固定高度：長文在框內捲動，不會把上方的名稱、日期、時區擠出畫面。
                    TextEditor(text: $rawText).frame(height: 180)
                        .accessibilityLabel("行程文字")
                        .overlay(alignment: .topLeading) {
                            if rawText.isEmpty {
                                Text("先貼上已有的文字行程；AI 讀完後再補必要資料").foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                } header: {
                    HStack {
                        Text("貼上文字行程")
                        Spacer()
                        if hasText {
                            Button("清除") { rawText = "" }.font(.caption).textCase(nil)
                        }
                    }
                } footer: {
                    Text("保留原日期、順序與固定事項；未知時間不補猜。確認預覽後才建立旅程。")
                }
                if !prepared {
                    Section {
                        Button(preparing ? "AI 正在讀取…" : "讓 AI 讀取行程") { Task { await prepare() } }
                            .disabled(preparing || rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rawText.count > 20000)
                        Button("手動填寫旅程資料") { prepared = true }
                    }
                } else {
                    if let summary { Section("原文摘要") { Text(summary) } }
                Section {
                    TextField("旅程名稱", text: Binding(get: { name }, set: { name = $0; nameAutoFilled = false }))
                    Toggle("確認以下旅行日期", isOn: $datesConfirmed)
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
                }
                if let errorMessage {
                    ErrorText(errorMessage)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: timeZoneID) { if !modeTouched { transportMode = TravelMode.suggested(forTimeZone: timeZoneID) } }
            .onChange(of: rawText) { persistDraft() }
            .onChange(of: name) { persistDraft() }
            .onChange(of: start) { persistDraft() }
            .onChange(of: end) { persistDraft() }
            .onChange(of: timeZoneID) { persistDraft() }
            .onChange(of: transportMode) { persistDraft() }
            .onChange(of: prepared) { persistDraft() }
            .onChange(of: datesConfirmed) { persistDraft() }
            .onChange(of: importSession?.id) { persistDraft() }
            .task { await restoreDraft() }
            .navigationTitle("建立旅程")
            .navigationDestination(item: $importSession) { importSession in
                ImportFlowView(session: importSession, service: session.imports, placeSearch: session.placeSearch,
                               discoveryRepository: InboxRepository(client: session.client)) { trip in
                    Task {
                        await applyMode(trip)
                        UserDefaults.standard.removeObject(forKey: draftKey)
                        finishCreation(trip)
                        dismiss()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "處理中…" : hasText ? "下一步" : "建立") { Task { await save() } }
                        .disabled(isSaving || !prepared || !datesConfirmed || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func finishCreation(_ trip: Trip) {
        // 先進 Today，用品建議背景產生；使用者不用等 AI 就能查看正式行程。
        onCreated(trip)
        Task { _ = try? await session.trips.ask(tripID: trip.id, question: PackingSuggestions.question, today: nil, routeFacts: []) }
    }
    private func persistDraft() {
        guard !restoringDraft else { return }
        if let data = try? JSONEncoder().encode(formDraft) { UserDefaults.standard.set(data, forKey: draftKey) }
    }
    private func restoreDraft() async {
        defer { restoringDraft = false }
        guard rawText.isEmpty else { return }
        if let data = UserDefaults.standard.data(forKey: draftKey), let draft = try? JSONDecoder().decode(FormDraft.self, from: data) {
            rawText = draft.rawText; name = draft.name; start = draft.start; end = draft.end
            timeZoneID = draft.timeZone; transportMode = draft.mode; modeTouched = true
            prepared = draft.prepared; datesConfirmed = draft.datesConfirmed; summary = draft.summary
            if let id = draft.importID {
                do {
                    let existing = try await session.imports.session(importID: id)
                    if existing.tripId == nil { importSession = existing }
                    else { UserDefaults.standard.removeObject(forKey: draftKey) }
                } catch { errorMessage = "原文已恢復，確認進度需連線後重開：\(userMessage(for: error))" }
            }
        } else { rawText = UserDefaults.standard.string(forKey: draftKey) ?? "" }
    }
    private var hasText: Bool {
        !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    }

    private func prepare() async {
        preparing = true
        defer { preparing = false }
        do {
            let result = try await session.trips.prepareTrip(text: rawText)
            name = result.title
            summary = result.summary
            if let zone = result.time_zone, TimeZone(identifier: zone) != nil { timeZoneID = zone }
            if let first = result.start_date.flatMap({ LocalDate.midnight($0, in: .current) }),
               let last = result.end_date.flatMap({ LocalDate.midnight($0, in: .current) }), last >= first {
                start = first; end = last
                datesConfirmed = true
            }
            prepared = true
            errorMessage = nil
        } catch { errorMessage = userMessage(for: error) }
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
        let importText = rawText
        let tripName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let startDate = LocalDate.string(from: start, timeZone: device)
        let endDate = LocalDate.string(from: max(start, end), timeZone: device)
        do {
            if hasText {
                importSession = try await session.imports.createImport(
                    tripName: tripName, startDate: startDate, endDate: endDate, timeZone: timeZoneID, rawText: importText)
            } else {
                let trip = try await session.trips.createTrip(name: tripName, startDate: startDate, endDate: endDate, timeZone: timeZoneID)
                await applyMode(trip)
                finishCreation(trip)
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
    var isArchived = false
    @State private var detailCachedAt: Date?
    @State private var timeline: [DayTimeline] = []
    @State private var places: [UUID: Place] = [:]
    @State private var saved: [SavedEntry] = []
    @State private var shopping: [ShoppingEntry] = []
    @State private var baseRoutes: [UUID: BaseRoute] = [:]
    @State private var errorMessage: String?
    @State private var showsRouteMatch = false
    @State private var showsAssistant = false
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
            if let detailCachedAt {
                Text("離線參考：\(detailCachedAt.formatted(date: .abbreviated, time: .shortened)) 保存的行程，重新連線後再編輯。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI 旅行助理") {
                AIResultsLink(session: session, trip: trip, canEdit: myRole?.canEdit == true)
                Button("討論這趟旅行", systemImage: "sparkles") { showsAssistant = true }
                if myRole?.canEdit == true {
                    NavigationLink("彙整待安排內容") {
                        TripAIPlanView(session: session, trip: trip) { Task { await reload() } }
                    }
                }
                Text("\(saved.filter { $0.saved.status == .saved }.count) 個收藏待安排 · \(shopping.filter { !$0.isPurchased }.count) 件商品未買齊")
                    .font(.caption).foregroundStyle(.secondary)
                Text("先保存想去、想吃、想買的內容，AI 提出安排，由你確認後加入行程。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("出發準備") {
                TripPreparationSummary(session: session, tripID: trip.id, revision: revision ?? trip.revision)
                NavigationLink("旅行必備用品") {
                    PackingView(session: session, trip: trip, canEdit: myRole?.canEdit == true)
                }
            }
            ForEach(timeline) { day in
                Section {
                    if day.stops.isEmpty {
                        Text("這天還沒有行程").foregroundStyle(.secondary)
                    }
                    ForEach(day.stops) { stop in
                        Button { selectedStop = stop } label: {
                            StopRow(stop: stop, place: stop.placeId.flatMap { places[$0] }, saved: savedFor(stop),
                                    shopping: shoppingFor(stop))
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
                    ScheduleReviewNotes(stops: day.stops,
                                        legs: baseRoutes[day.id].flatMap { $0.routeRevision == day.day.routeRevision ? $0.legs : nil } ?? [])
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
                        if let owner = session.trips.currentUserID {
                            SnapshotCache.forOwner(owner)?.remove(tripID: trip.id)
                            TripCatalogCache.shared(owner: owner)?.removeTrip(trip.id)
                        }
                        onDeleted()
                        dismissView()
                    } catch let e as BackendError { errorMessage = e.userMessage } catch {}
                }
            }
        }
        .sheet(item: $selectedStop) { stop in
            StopDetailView(stop: stop, place: stop.placeId.flatMap { places[$0] }, saved: savedFor(stop),
                           shopping: shoppingFor(stop),
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
                           canEdit: myRole?.canEdit == true, allowAutomaticDiscovery: !isArchived && detailCachedAt == nil)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsAssistant) {
            AssistantView(session: session, snapshot: TripSnapshot(trip: trip, revision: revision ?? trip.revision,
                timeline: timeline, places: places, saved: saved, shopping: shopping), canApply: myRole?.canEdit == true) {
                Task { await reload() }
            }
        }
        .navigationTitle(trip.name)
        // toolbar 只留一個主要動作「試算順路」，其餘收進「更多」。
        .toolbar {
            Button("AI 助手", systemImage: "sparkles") { showsAssistant = true }
                .disabled(timeline.isEmpty)
            Menu("更多", systemImage: "ellipsis.circle") {
                Button("試算順路") { showsRouteMatch = true }
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

    private func savedFor(_ stop: Stop) -> SavedEntry? {
        saved.first {
            $0.saved.plannedStopId == stop.id ||
                ($0.saved.arrangementDetached != true && $0.saved.plannedStopId == nil && $0.saved.placeId != nil && $0.saved.placeId == stop.placeId)
        }
    }

    private func shoppingFor(_ stop: Stop) -> ShoppingEntry? {
        shopping.first { $0.item.plannedStopId == stop.id || ($0.extraVisits ?? []).contains { $0.id == stop.id } }
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
            async let sv = session.trips.savedEntries(of: trip.id)
            async let sh = session.trips.shoppingEntries(of: trip.id)
            let (days, stops, savedEntries, shoppingEntries) = try await (d, s, sv, sh)
            saved = savedEntries
            shopping = shoppingEntries
            let placeList = try await session.trips.places(ids: Array(Set(stops.compactMap(\.placeId))))
            places = Dictionary(uniqueKeysWithValues: placeList.map { ($0.id, $0) })
            timeline = DayTimeline.build(days: days, stops: stops)
            revision = try await session.trips.tripRevision(trip.id)
            myRole = try await session.trips.myRole(in: trip.id)
            detailCachedAt = nil
            if let owner = session.trips.currentUserID {
                SnapshotCache.forOwner(owner)?.save(TripSnapshot(trip: trip, revision: revision ?? trip.revision,
                    timeline: timeline, places: places, saved: saved, shopping: shopping))
            }
            errorMessage = nil
        } catch {
            myRole = nil; baseRoutes = [:]
            if case .other = BackendError.from(error), let owner = session.trips.currentUserID,
               let cached = SnapshotCache.forOwner(owner)?.load(tripID: trip.id) {
                timeline = cached.snapshot.timeline; places = cached.snapshot.places
                saved = cached.snapshot.saved; shopping = cached.snapshot.shopping
                revision = cached.snapshot.revision; detailCachedAt = cached.savedAt
            } else {
                timeline = []; places = [:]; saved = []; shopping = []; detailCachedAt = nil
                if let owner = session.trips.currentUserID { SnapshotCache.forOwner(owner)?.remove(tripID: trip.id) }
            }
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
    var saved: SavedEntry? = nil
    var shopping: ShoppingEntry? = nil
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
    var allowAutomaticDiscovery = true
    @State private var nearbyArrangement: SavedEntry?
    @Environment(\.dismiss) private var dismissDetail

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(place?.displayTitle(fallbackChinese: stop.rawLabel) ?? stop.rawLabel).font(.title3.weight(.semibold))
                    if let address = place?.localAddress ?? stop.destinationAddress ?? saved?.addressLabel ?? shopping?.item.scheduledStoreAddressLocal {
                        Text(place == nil ? "地址線索：\(address)" : address)
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Button("複製店名", systemImage: "doc.on.doc") {
                        copyDestination(stop.destinationName ?? place?.nameLocal ?? place?.name ?? stop.rawLabel)
                    }
                    if let address = place?.localAddress ?? stop.destinationAddress ?? saved?.addressLabel ?? shopping?.item.scheduledStoreAddressLocal,
                       !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("複製地址", systemImage: "doc.on.doc") { copyDestination(address) }
                    }
                    if let start = stop.startTime { LabeledContent("時間", value: LocalTime.hourMinute(start)) }
                    if let dwell = stop.dwellMinutes { LabeledContent("停留", value: "\(dwell) 分") }
                    if stop.fixed { Label("固定行程", systemImage: "lock.fill").foregroundStyle(.secondary) }
                    if let shopping {
                        Text("要買：\(shopping.item.name) · 可詢問，販售與庫存未知")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if place == nil { Text("未定位，不計入路線").font(.caption).foregroundStyle(.secondary) }
                }
                if place == nil {
                    let country = LocalMapCountry.guess(name: stop.rawLabel, timeZone: timeZone)
                    Section {
                        TaxiCardButton(unlocatedName: stop.destinationName ?? stop.rawLabel, countryCode: country,
                                       addressHint: stop.destinationAddress ?? saved?.saved.addressHint ?? shopping?.item.scheduledStoreAddressLocal, fallbackChineseLabel: stop.rawLabel)
                    }
                    Section {
                        LocalMapSearchButtons(name: stop.rawLabel,
                                              localAddress: stop.destinationAddress ?? saved?.saved.addressHint ?? shopping?.item.scheduledStoreAddressLocal,
                                              countryCode: country)
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
                        TaxiCardButton(place: place, fallbackChineseLabel: stop.rawLabel,
                                       fallbackAddress: saved?.saved.addressHint ?? shopping?.item.scheduledStoreAddressLocal)
                    }
                }
                if let place, place.isInKorea {
                    Section("在地地圖") {
                        LocalMapButtons(destination: place.mapPoint, origin: previous?.mapPoint, mode: mode, address: place.localAddress)
                    }
                }
                if let source = saved?.source?.url.flatMap(URL.init(string:)), source.scheme == "https" {
                    Section("收藏來源") { Link(source.host ?? "查看來源", destination: source) }
                }
                if let source = shopping?.item.scheduledStoreSourceURL.flatMap(URL.init(string:)), source.scheme == "https" {
                    Section("店家線索來源") { Link(source.host ?? "查看來源", destination: source) }
                }
                if let session {
                    StationExploreSection(session: session, stop: stop, canEdit: canEdit, automatic: allowAutomaticDiscovery) { nearbyArrangement = $0 }
                    Section("AI 附近探索") {
                        NavigationLink("針對本站問 AI") {
                            StopAssistantView(session: session, stop: stop, canApply: canEdit)
                        }
                        Text("詢問附近美食、景點、當日活動或廁所；以本站為起點，不需先在地圖找到店家。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(item: $nearbyArrangement) { entry in
                if let session {
                    NavigationStack { SavedScheduleView(session: session, entry: entry) { _ in nearbyArrangement = nil } }
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
    var saved: SavedEntry? = nil
    var shopping: ShoppingEntry? = nil

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
                    if let address = saved?.saved.addressHint ?? shopping?.item.scheduledStoreAddressLocal {
                        Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                } else if let address = place?.localAddress ?? stop.destinationAddress ?? saved?.addressLabel ?? shopping?.item.scheduledStoreAddressLocal {
                    Text(address).font(.caption).foregroundStyle(.secondary)
                }
                if let shopping {
                    Text("要買：\(shopping.item.name) · 庫存未知")
                        .font(.caption).foregroundStyle(.secondary)
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

private func copyDestination(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

private struct StopAssistantView: View {
    let session: SessionModel
    let stop: Stop
    let canApply: Bool
    @State private var snapshot: TripSnapshot?
    @State private var errorMessage: String?
    var body: some View {
        Group {
            if let snapshot {
                AssistantView(session: session, snapshot: snapshot, canApply: canApply, onApplied: {}, focusStop: stop)
            } else if let errorMessage { ErrorText(errorMessage) }
            else { ProgressView("讀取本站行程…") }
        }.task {
            do {
                guard let trip = try await session.trips.allTrips().first(where: { $0.id == stop.tripId }) else { errorMessage = "這份旅程已不存在，或你已沒有存取權限。"; return }
                snapshot = try await session.trips.snapshot(of: trip)
            } catch { errorMessage = userMessage(for: error) }
        }
    }
}
