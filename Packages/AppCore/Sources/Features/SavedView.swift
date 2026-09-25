import AppCore
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
                if trips.count > 1 {
                    Picker("旅程", selection: $tripID) {
                        ForEach(trips) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Picker("類別", selection: $filter) {
                    ForEach(SavedFilter.tabs, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                Toggle("顯示已加入行程", isOn: $includeAdded)

                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                if queued > 0 {
                    Label("\(queued) 項變更等待連線後送出", systemImage: "icloud.slash").font(.caption).foregroundStyle(.secondary)
                }

                ForEach(filter.apply(entries, includeAdded: includeAdded)) { entry in
                    SavedRow(entry: entry, me: session.trips.currentUserID, canEdit: myRole?.canEdit == true,
                             toggleInterest: { Task { await toggleInterest(entry) } },
                             showRoute: { routeFor = entry },
                             resolve: { resolving = entry })
                    .swipeActions {
                        if myRole?.canEdit == true {
                            Button("移除", role: .destructive) { Task { await dismiss(entry) } }
                        }
                    }
                }
            }
            .overlay {
                if loaded && trips.isEmpty {
                    ContentUnavailableView("尚未建立行程", systemImage: "bookmark")
                } else if loaded && filter.apply(entries, includeAdded: includeAdded).isEmpty && drafts.isEmpty {
                    ContentUnavailableView("尚未收藏地點", systemImage: "bookmark",
                                           description: Text("從 Threads、IG 或地圖 App 分享到 BearTravel。"))
                }
            }
            .navigationTitle("收藏")
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
            errorMessage = "讀取失敗：\(error.localizedDescription)"
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
            errorMessage = "讀取失敗：\(error.localizedDescription)"
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
            errorMessage = "更新失敗：\(error.localizedDescription)"
        }
    }

    private func dismiss(_ entry: SavedEntry) async {
        do {
            try await session.trips.dismissSaved(savedID: entry.id)
            await reload()
        } catch {
            errorMessage = "移除失敗：\(error.localizedDescription)"
        }
    }
}

struct SavedRow: View {
    let entry: SavedEntry
    let me: UUID?
    let canEdit: Bool
    let toggleInterest: () -> Void
    let showRoute: () -> Void
    let resolve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.title).font(.headline)
                Spacer()
                Text(entry.saved.category.displayName).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if !entry.isConfirmed {
                Label("地點待確認，不參與路線", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
            } else if entry.saved.status == .addedToItinerary {
                Label("已加入行程", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let source = entry.source, let url = source.url.flatMap(URL.init(string:)) {
                Link(url.host ?? url.absoluteString, destination: url).font(.caption)
            }
            if let place = entry.place {
                TaxiCardButton(place: place, fallbackChineseLabel: entry.saved.rawLabel)
                    .font(.caption).buttonStyle(.borderless)
            }
            HStack(spacing: 16) {
                Text(entry.saved.addedBy == nil ? "已刪除帳號的成員新增" : entry.saved.addedBy == me ? "你新增" : "旅伴新增").font(.caption).foregroundStyle(.secondary)
                Button {
                    toggleInterest()
                } label: {
                    Label("\(entry.interestedUserIDs.count) 人想去",
                          systemImage: me.map(entry.interestedUserIDs.contains) == true ? "heart.fill" : "heart")
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
                    HStack {
                        TextField("店名或地點", text: $query).onSubmit { Task { await search() } }
                        Button("搜尋") { Task { await search() } }
                    }
                    ForEach(results) { option in
                        Button {
                            Task { await choose(option) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(option.displayTitle)
                                if let address = option.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("補填地點")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear { query = entry.saved.rawLabel }
        }
    }

    private func search() async {
        results = await session.placeSearch.search(query, around: await session.trips.center(of: entry.saved.tripId), limit: 6)
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
            errorMessage = "補填失敗：\(error.localizedDescription)"
        }
    }
}
