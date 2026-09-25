import AppCore
import PhotosUI
import ShareCore
import SwiftUI

/// Saved 分頁（規格 §3.5）：共同收藏的地點，不是正式行程。
struct SavedView: View {
    let session: SessionModel
    @State private var trips: [Trip] = []
    @State private var tripID: UUID?
    @State private var entries: [SavedEntry] = []
    @State private var filter: SavedFilter = .all
    @State private var includeAdded = false
    @State private var drafts: [ShareDraft] = []
    @State private var openDraft: ShareDraft?
    @State private var routeFor: SavedEntry?
    @State private var resolving: SavedEntry?
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var myRole: TripRole?
    @State private var sync: TripSync?
    @State private var queued = 0
    @State private var adding = false
    @State private var detail: SavedEntry?

    var body: some View {
        NavigationStack {
            List {
                if !drafts.isEmpty {
                    Section("待處理的分享") {
                        ForEach(drafts) { draft in
                            Button {
                                openDraft = draft
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(draft.content.urls.first?.host ?? draft.content.texts.first ?? "分享")
                                    Text(draft.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Picker("類別", selection: $filter) {
                    ForEach(SavedFilter.tabs, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                Toggle("顯示已加入行程", isOn: $includeAdded)

                if let errorMessage { ErrorText(errorMessage) }
                if queued > 0 {
                    Label("\(queued) 項變更等待連線後送出", systemImage: "icloud.slash").font(.caption).foregroundStyle(.secondary)
                }

                ForEach(filter.apply(entries, includeAdded: includeAdded)) { entry in
                    SavedRow(entry: entry, me: session.trips.currentUserID, canEdit: myRole?.canEdit == true,
                             toggleInterest: { Task { await toggleInterest(entry) } },
                             showRoute: { routeFor = entry },
                             resolve: { resolving = entry },
                             open: { detail = entry })
                    .swipeActions {
                        if myRole?.canEdit == true {
                            Button("移除", role: .destructive) { Task { await dismiss(entry) } }
                        }
                    }
                }
            }
            .overlay {
                if loaded && trips.isEmpty {
                    ContentUnavailableView("還沒有旅程", systemImage: "bookmark", description: Text("先到「旅程」建立或加入旅程。"))
                } else if loaded && filter.apply(entries, includeAdded: includeAdded).isEmpty && drafts.isEmpty {
                    ContentUnavailableView("還沒有收藏", systemImage: "bookmark",
                                           description: Text("按右上角 ＋ 新增，或從 Threads、IG、地圖 App 分享到 BeaRTravel。"))
                }
            }
            .navigationTitle("收藏")
            // 換旅程與今天、購物一樣放在工具列。
            .toolbar {
                if trips.count > 1 {
                    ToolbarItem(placement: .automatic) {
                        Picker("旅程", selection: $tripID) {
                            ForEach(trips) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
                if myRole?.canEdit == true, tripID != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("新增地點", systemImage: "plus") { adding = true }
                            .accessibilityIdentifier("addSaved")
                    }
                }
            }
            .sheet(isPresented: $adding) {
                if let tripID {
                    AddSavedPlaceView(session: session, tripID: tripID) {
                        adding = false
                        Task { await reload() }
                    }
                }
            }
            .refreshable { await reload() }
            .task { await loadTrips() }
            .onChange(of: tripID) { Task { await switchTrip() } }
            .sheet(item: $openDraft) { draft in
                NavigationStack {
                    ShareFlowView(content: draft.content, repository: session.trips, matcher: session.routes,
                                  placeSearch: session.placeSearch, saveDraft: nil) { _ in
                        ShareDraftStore.shared()?.remove(draft.id)
                        openDraft = nil
                        Task { await reload() }
                    }
                    .navigationTitle("處理分享")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { openDraft = nil } } }
                }
            }
            .sheet(item: $routeFor) { entry in
                if let tripID, let place = entry.place {
                    SavedRouteSheet(session: session, tripID: tripID, place: place, category: entry.saved.category, canEdit: myRole?.canEdit == true) {
                        Task { await reload() }
                    }
                }
            }
            .sheet(item: $detail) { entry in
                SavedDetailView(entry: entry, me: session.trips.currentUserID)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $resolving) { entry in
                ResolvePlaceSheet(session: session, entry: entry) {
                    resolving = nil
                    Task { await reload() }
                }
            }
        }
    }

    private func loadTrips() async {
        drafts = ShareDraftStore.shared()?.all() ?? []
        do {
            trips = try await session.trips.myTrips()
            if tripID == nil { tripID = ShareFlowView.defaultTrip(trips)?.id }
        } catch {
            errorMessage = "讀取失敗：\(userMessage(for: error))"
        }
        loaded = true
        await reload()
    }

    /// 換 Trip 時重新取得權限並改訂閱該 Trip 的變更（WP7）。
    private func switchTrip() async {
        await sync?.stop()
        sync = nil
        guard let tripID else { return }
        myRole = try? await session.trips.myRole(in: tripID)
        await reload()
        if let revision = try? await session.trips.tripRevision(tripID) {
            let sync = TripSync(tripID: tripID, repository: session.trips, revision: revision) { events in
                if events.contains(where: { $0.kind.hasPrefix("saved.") || $0.kind.hasPrefix("day.") }) { Task { await reload() } }
            }
            self.sync = sync
            await sync.start()
        }
    }

    private func reload() async {
        drafts = ShareDraftStore.shared()?.all() ?? []
        await session.flushOfflineQueue()
        queued = await session.offlineQueue.items.count
        guard let tripID else { return }
        do {
            entries = try await session.trips.savedEntries(of: tripID)
            errorMessage = nil
        } catch {
            errorMessage = "讀取失敗：\(userMessage(for: error))"
        }
    }

    /// 想去可離線（決策 D6）：連不上時先更新畫面並排入佇列。
    private func toggleInterest(_ entry: SavedEntry) async {
        guard let me = session.trips.currentUserID else { return }
        let interested = !entry.interestedUserIDs.contains(me)
        do {
            try await session.trips.setInterest(savedID: entry.id, interested: interested)
            await reload()
        } catch BackendError.other {
            await session.offlineQueue.enqueue(.setInterest(savedID: entry.id, interested: interested))
            if let i = entries.firstIndex(where: { $0.id == entry.id }) {
                if interested { entries[i].interestedUserIDs.insert(me) } else { entries[i].interestedUserIDs.remove(me) }
            }
            queued = await session.offlineQueue.items.count
        } catch {
            errorMessage = "更新失敗：\(userMessage(for: error))"
        }
    }

    private func dismiss(_ entry: SavedEntry) async {
        do {
            try await session.trips.dismissSaved(savedID: entry.id)
            await reload()
        } catch {
            errorMessage = "移除失敗：\(userMessage(for: error))"
        }
    }
}

/// 收藏列：標題、一行狀態、想去與一個主要動作；其餘（來源、司機卡、當地地圖）點列進詳情。
struct SavedRow: View {
    let entry: SavedEntry
    let me: UUID?
    let canEdit: Bool
    let toggleInterest: () -> Void
    let showRoute: () -> Void
    let resolve: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
            Text(SavedRow.status(entry, me: me)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button {
                    toggleInterest()
                } label: {
                    Label("\(entry.interestedUserIDs.count) 人想去",
                          systemImage: me.map(entry.interestedUserIDs.contains) == true ? "heart.fill" : "heart")
                        .monospacedDigit()
                }
                .disabled(!canEdit)
                Spacer()
                if entry.isConfirmed {
                    if entry.saved.status == .saved { Button("試算順路", action: showRoute) }
                } else if canEdit {
                    Button("補填地點", action: resolve)
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    static func status(_ entry: SavedEntry, me: UUID?) -> String {
        var parts = [entry.saved.category.displayName]
        if !entry.isConfirmed {
            parts.append("未定位")
        } else if entry.saved.status == .addedToItinerary {
            parts.append("已加入行程")
        }
        parts.append(entry.saved.addedBy == nil ? "已刪除帳號的成員新增" : entry.saved.addedBy == me ? "你新增" : "旅伴新增")
        return parts.joined(separator: " · ")
    }
}

/// 收藏詳情：來源、司機卡、當地地圖。
struct SavedDetailView: View {
    let entry: SavedEntry
    let me: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(entry.title).font(.title3.weight(.semibold))
                    if let address = entry.place?.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                    Text(SavedRow.status(entry, me: me)).font(.caption).foregroundStyle(.secondary)
                    if !entry.isConfirmed {
                        Label("未定位，不計入路線", systemImage: "mappin.slash").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let source = entry.source, let url = source.url.flatMap(URL.init(string:)) {
                    Section("來源") { Link(url.host ?? url.absoluteString, destination: url) }
                }
                Section {
                    if let place = entry.place {
                        NavigateButton(destination: place.mapPoint, mode: .walking)
                        TaxiCardButton(place: place, fallbackChineseLabel: entry.saved.rawLabel)
                    } else {
                        let country = LocalMapCountry.guess(name: entry.saved.rawLabel, timeZone: nil)
                        TaxiCardButton(unlocatedName: entry.saved.rawLabel, countryCode: country)
                        LocalMapSearchButtons(name: entry.saved.rawLabel, countryCode: country)
                    }
                }
                if let place = entry.place, place.isInKorea {
                    Section("在地地圖") {
                        LocalMapButtons(destination: place.mapPoint, origin: nil, mode: .walking, address: place.localAddress)
                    }
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayModeInline()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

/// 從 Saved 試算並加入行程：載入時間軸後沿用試算順路畫面。
struct SavedRouteSheet: View {
    let session: SessionModel
    let tripID: UUID
    let place: Place
    let category: SavedCategory
    let canEdit: Bool
    let onAdded: () -> Void
    @State private var timeline: [DayTimeline]?
    @State private var places: [UUID: Place] = [:]

    var body: some View {
        Group {
            if let timeline {
                RouteMatchView(session: session, tripID: tripID, timeline: timeline, places: places, onAdded: onAdded,
                               preset: SearchResult(draft: place.asDraft),
                               canEdit: canEdit)
            } else {
                ProgressView()
            }
        }
        .task {
            guard let days = try? await session.trips.days(of: tripID), let stops = try? await session.trips.stops(of: tripID),
                  let list = try? await session.trips.places(ids: Array(Set(stops.compactMap(\.placeId)))) else { return }
            places = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            timeline = DayTimeline.build(days: days, stops: stops)
        }
    }
}

/// 手動補填未確認的地點（AC-04）：搜尋後由使用者選定。
struct ResolvePlaceSheet: View {
    let session: SessionModel
    let entry: SavedEntry
    let onDone: () -> Void
    @State private var query = ""
    @State private var results: [PlaceOption] = []
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("「\(entry.saved.rawLabel)」") {
                    PlaceSearchField(text: $query) { Task { await search() } }
                    ForEach(results) { option in
                        Button {
                            Task { await choose(option) }
                        } label: {
                            PlaceOptionRow(title: option.displayTitle, address: option.address)
                        }
                    }
                }
                if let errorMessage { ErrorText(errorMessage) }
            }
            .navigationTitle("補填地點")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear { query = entry.saved.rawLabel }
        }
    }

    private func search() async {
        results = await session.placeSearch.search(query, in: await session.trips.searchAreas(of: entry.saved.tripId), limit: 6)
        errorMessage = results.isEmpty ? "找不到符合的地點" : nil
    }

    private func choose(_ option: PlaceOption) async {
        do {
            let place = try await session.trips.upsertPlace(option.draft)
            try await session.trips.resolveSaved(savedID: entry.id, placeID: place.id)
            onDone()
        } catch BackendError.conflict("DUPLICATE_SAVED") {
            errorMessage = "這個地點已經在收藏清單裡。"
        } catch {
            errorMessage = "補填失敗：\(userMessage(for: error))"
        }
    }
}

/// 直接在收藏頁新增地點：搜尋 Apple 地圖選一個，或只保留名稱（之後可補定位）。
/// 收藏只進共同的收藏清單，不改正式行程。
struct AddSavedPlaceView: View {
    let session: SessionModel
    let tripID: UUID
    let onDone: () -> Void
    @State private var query = ""
    @State private var category: SavedCategory = .place
    /// 沒自己選類別時，用地圖上的店家類型（餐廳、咖啡廳…）。
    @State private var categoryChosen = false
    @State private var results: [PlaceOption] = []
    @State private var searched = false
    @State private var searching = false
    @State private var saving = false
    @State private var areas: SearchAreas?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    /// 貼進來的是分享連結（地圖、IG、Threads、網頁）時，用分享流程解析。
    private var pastedURL: URL? { ShareAnalysis.urls(in: query).first }
    @State private var photo: PhotosPickerItem?
    @State private var screenshot: ScreenshotImport?

    struct ScreenshotImport: Identifiable, Hashable {
        let id = UUID()
        let jpeg: Data
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PlaceSearchField(text: $query, placeholder: "店名、地點，或貼上分享連結", isSearching: searching) { Task { await search() } }
                        .accessibilityIdentifier("savedQuery")
                    Picker("類別", selection: Binding(get: { category }, set: { category = $0; categoryChosen = true })) {
                        ForEach(SavedCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("從截圖辨識店名與地址", systemImage: "text.viewfinder")
                    }
                } footer: {
                    Text("在手機上讀出截圖裡的店名、地址再搜尋，不會上傳。")
                }
                if let url = pastedURL {
                    Section {
                        NavigationLink {
                            ShareFlowView(content: ShareContent(urls: [url], texts: [trimmed]), repository: session.trips,
                                          matcher: session.routes, placeSearch: session.placeSearch, saveDraft: nil) { _ in onDone() }
                                .navigationTitle("解析連結")
                        } label: {
                            Label("解析這個連結", systemImage: "link")
                        }
                        .accessibilityIdentifier("parseLink")
                    } footer: {
                        Text("地圖連結（Google、Apple、Naver、Kakao）會直接讀出地點；IG、Threads 若只拿得到連結，請補上店名。解析後可以收藏，或直接排進某一天（先看多花幾分鐘再確認）。")
                    }
                }
                if searching { ProgressView("搜尋中…") }
                if !results.isEmpty {
                    Section("Apple 地圖") {
                        ForEach(results) { option in
                            Button { Task { await save(option) } } label: {
                                PlaceOptionRow(title: option.displayTitle, address: option.address)
                            }
                            .disabled(saving)
                        }
                    }
                }
                if searched && !trimmed.isEmpty {
                    Section {
                        Button("只收藏名稱「\(trimmed)」") { Task { await save(nil) } }
                            .disabled(saving)
                        LocalMapSearchButtons(name: trimmed, countryCode: LocalMapCountry.guess(name: trimmed, timeZone: nil)
                                              ?? (areas?.countries.count == 1 ? areas?.countries.first : nil))
                    } header: {
                        Text(results.isEmpty ? "Apple 地圖沒找到" : "都不是？")
                    } footer: {
                        Text("只收藏名稱時不計入路線，之後可以再補定位。")
                    }
                }
                if let errorMessage { ErrorText(errorMessage) }
            }
            .navigationDestination(item: $screenshot) { shot in
                ShareFlowView(content: ShareContent(hasImage: true, imageJPEG: shot.jpeg), repository: session.trips,
                              matcher: session.routes, placeSearch: session.placeSearch, saveDraft: nil) { _ in onDone() }
                    .navigationTitle("辨識截圖")
            }
            .onChange(of: photo) {
                Task {
                    guard let data = try? await photo?.loadTransferable(type: Data.self),
                          let jpeg = ImageDownscale.jpeg(from: data, maxPixel: 2048) else { return }
                    photo = nil
                    screenshot = ScreenshotImport(jpeg: jpeg)
                }
            }
            .navigationTitle("新增收藏")
            .navigationBarTitleDisplayModeInline()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func search() async {
        guard !trimmed.isEmpty else { return }
        searching = true
        defer { searching = false; searched = true }
        if areas == nil { areas = await session.trips.searchAreas(of: tripID) }
        results = await session.placeSearch.search(trimmed, in: areas ?? .none, limit: 6)
    }

    private func save(_ option: PlaceOption?) async {
        saving = true
        defer { saving = false }
        do {
            let placeID = if let option { try await session.trips.upsertPlace(option.draft).id } else { UUID?.none }
            let kind = categoryChosen ? category : option?.category ?? category
            _ = try await session.trips.savePlace(tripID: tripID, label: option?.name ?? trimmed, category: kind,
                                                  placeID: placeID, source: nil)
            onDone()
        } catch let error as BackendError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "收藏失敗：\(userMessage(for: error))"
        }
    }
}
