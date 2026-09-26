import AppCore
import PhotosUI
import ShareCore
import SwiftUI

/// Saved 分頁（規格 §3.5）：共同收藏的地點，不是正式行程。
struct SavedView: View {
    let session: SessionModel
    var preferredTripID: UUID? = nil
    var onOpenDay: (UUID, UUID) -> Void = { _, _ in }
    var onTripSelected: (UUID?) -> Void = { _ in }
    @State private var trips: [Trip] = []
    @State private var tripID: UUID?
    @State private var entries: [SavedEntry] = []
    @State private var filter: SavedFilter = .all
    @State private var drafts: [ShareDraft] = []
    @State private var openDraft: ShareDraft?
    @State private var scheduling: SavedEntry?
    @State private var scheduledDays: [UUID: TripDay] = [:]
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var myRole: TripRole?
    @State private var sync: TripSync?
    @State private var queued = 0
    @State private var adding = false
    @State private var detail: SavedEntry?
    @State private var personalItems: [InboxItemRecord] = []
    @State private var candidateItems: [InboxItemRecord] = []
    @State private var recentCaptures: [InboxRecord] = []
    @State private var localCaptures = 0
    @State private var inboxError: String?
    @State private var discoveringPlaces = false
    @State private var showsInbox = false
    @Environment(\.scenePhase) private var scenePhase

    private var inbox: InboxRepository { InboxRepository(client: session.client) }

    var body: some View {
        NavigationStack {
            List {
                if localCaptures > 0 || !recentCaptures.isEmpty {
                    Section("最近分享") {
                        if localCaptures > 0 {
                            Button("\(localCaptures) 份分享保存在此裝置 · 查看同步狀態") { showsInbox = true }
                        }
                        ForEach(recentCaptures.prefix(3)) { capture in
                            Button {
                                showsInbox = true
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(capture.title ?? capture.publicText.map { String($0.prefix(40)) }
                                         ?? capture.sourceURL.flatMap { URL(string: $0)?.host } ?? "分享內容")
                                        .lineLimit(1)
                                    Text(inboxStatus(capture.status)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let inboxError { ErrorText(inboxError) }
                if discoveringPlaces { ProgressView("正在查韓文店名與地址…") }
                if !personalItems.isEmpty {
                    Section("我的收藏") {
                        ForEach(personalItems) { item in
                            PersonalInboxRow(item: item, kind: "place", repository: inbox) { _ in
                                Task { await loadInbox() }
                            }
                            .swipeActions {
                                Button("撤銷", role: .destructive) { Task { await undoPersonal(item) } }
                            }
                        }
                    }
                }
                if !candidateItems.isEmpty {
                    Section("待確認的地點") {
                        ForEach(candidateItems) { item in
                            PersonalInboxRow(item: item, kind: "place", repository: inbox, candidate: true) { _ in
                                Task { await loadInbox() }
                            }
                        }
                    }
                }
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

                if let errorMessage { ErrorText(errorMessage) }
                if queued > 0 {
                    Label("\(queued) 項變更等待連線後送出", systemImage: "icloud.slash").font(.caption).foregroundStyle(.secondary)
                }

                if !entries.isEmpty {
                    Section("旅伴共同收藏") {
                        ForEach(filter.apply(entries, includeAdded: true)) { entry in
                            SavedRow(entry: entry, me: session.trips.currentUserID, canEdit: myRole?.canEdit == true,
                                     scheduledDay: scheduledDays[entry.id],
                                     toggleInterest: { Task { await toggleInterest(entry) } },
                                     schedule: { scheduling = entry },
                                     showDay: { if let day = scheduledDays[entry.id] { onOpenDay(entry.saved.tripId, day.id) } },
                                     open: { detail = entry })
                            .swipeActions {
                                if myRole?.canEdit == true {
                                    Button("移除", role: .destructive) { Task { await dismiss(entry) } }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if loaded && trips.isEmpty && personalItems.isEmpty && candidateItems.isEmpty && recentCaptures.isEmpty && localCaptures == 0 {
                    ContentUnavailableView("還沒有旅程", systemImage: "bookmark", description: Text("先到「旅程」建立或加入旅程。"))
                } else if loaded && filter.apply(entries, includeAdded: true).isEmpty && drafts.isEmpty &&
                            personalItems.isEmpty && candidateItems.isEmpty && recentCaptures.isEmpty && localCaptures == 0 {
                    ContentUnavailableView("還沒有收藏", systemImage: "bookmark",
                                           description: Text("按右上角 ＋ 新增，或從 Threads、IG、地圖 App 分享到 BeaRTravel。"))
                }
            }
            .navigationTitle("收藏")
            // 換旅程與今天、購物一樣放在工具列。
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button("分享收件匣", systemImage: "tray") { showsInbox = true }
                }
                ToolbarItem(placement: .secondaryAction) {
                    NavigationLink {
                        PersonalInboxItemsView(session: session, kind: "place")
                    } label: { Label("個人收藏", systemImage: "person.crop.circle") }
                }
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
            .task { await loadTrips(); await refreshInboxUntilSettled() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await reload(); await refreshInboxUntilSettled() } }
            }
            .onChange(of: tripID) { _, selected in
                if selected != nil { onTripSelected(selected) }
                Task { await switchTrip() }
            }
            .onChange(of: preferredTripID) { _, selected in
                if let selected, selected != tripID, trips.contains(where: { $0.id == selected }) { tripID = selected }
            }
            .sheet(item: $openDraft) { draft in
                NavigationStack {
                    ShareFlowView(content: draft.content, repository: session.trips, matcher: session.routes,
                                  placeSearch: session.placeSearch, saveDraft: nil,
                                  discoveryRepository: inbox, preferredTripID: tripID) { _ in
                        ShareDraftStore.shared()?.remove(draft.id)
                        openDraft = nil
                        Task { await reload() }
                    }
                    .navigationTitle("處理分享")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { openDraft = nil } } }
                }
            }
            .sheet(item: $scheduling) { entry in
                NavigationStack {
                    SavedScheduleView(session: session, entry: entry) { dayID in
                        scheduling = nil
                        Task { await reload() }
                        onOpenDay(entry.saved.tripId, dayID)
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { scheduling = nil }
                    } }
                }
            }
            .sheet(item: $detail) { entry in
                SavedDetailView(session: session, entry: entry, me: session.trips.currentUserID,
                                canEdit: myRole?.canEdit == true, scheduledDay: scheduledDays[entry.id],
                                tripCountry: trips.first(where: { $0.id == tripID }).flatMap {
                                    LocalMapCountry.guess(name: $0.name, timeZone: $0.timeZone)
                                }, repository: session.trips, discoveryRepository: inbox) {
                    Task { await reload() }
                } onOpenDay: { dayID in onOpenDay(entry.saved.tripId, dayID) }
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showsInbox) { InboxView(session: session) }
        }
    }

    private func loadTrips() async {
        drafts = ShareDraftStore.shared()?.all() ?? []
        do {
            trips = try await session.trips.myTrips()
            if tripID == nil { tripID = trips.first { $0.id == preferredTripID }?.id ?? ShareFlowView.defaultTrip(trips)?.id }
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
        await loadInbox()
        await session.flushOfflineQueue()
        queued = await session.offlineQueue.items.count
        guard let tripID else {
            entries = []
            scheduledDays = [:]
            return
        }
        do {
            entries = try await session.trips.savedEntries(of: tripID)
            errorMessage = nil
        } catch {
            entries = []
            scheduledDays = [:]
            errorMessage = "收藏讀取失敗：\(userMessage(for: error))"
            return
        }
        do {
            async let days = session.trips.days(of: tripID)
            async let stops = session.trips.stops(of: tripID)
            let (loadedDays, loadedStops) = try await (days, stops)
            let dayByID = Dictionary(uniqueKeysWithValues: loadedDays.map { ($0.id, $0) })
            scheduledDays = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                let stop = loadedStops.first {
                    $0.id == entry.saved.plannedStopId ||
                        (entry.saved.plannedStopId == nil && entry.saved.placeId != nil && $0.placeId == entry.saved.placeId)
                }
                return stop.flatMap { dayByID[$0.dayId] }.map { (entry.id, $0) }
            })
            errorMessage = nil
        } catch {
            scheduledDays = [:]
            errorMessage = "收藏已載入，行程日期暫時無法更新：\(userMessage(for: error))"
        }
    }

    private func loadInbox() async {
        let me = session.trips.currentUserID
        localCaptures = (InboxCaptureStore.shared()?.all() ?? [])
            .filter { ($0.ownerHint == nil || $0.ownerHint == me) && $0.syncedRemoteID == nil }.count
        do {
            async let personal = inbox.listPersonalItems(kind: "place")
            async let candidates = inbox.listPersonalCandidates(kind: "place")
            async let captures = inbox.listCaptures()
            (personalItems, candidateItems, recentCaptures) = try await (personal, candidates, captures)
            inboxError = nil
        } catch {
            inboxError = "分享內容暫時無法讀取：\(userMessage(for: error))"
        }
    }

    private func refreshInboxUntilSettled() async {
        await session.syncInboxCaptures()
        for _ in 0..<30 {
            if Task.isCancelled { return }
            await loadInbox()
            await discoverRecentPlaces()
            if !recentCaptures.contains(where: { $0.status == "saved" || $0.status == "processing" }) { return }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// 分享整理完成後自動補韓文店名與地址線索，使用者不用先進確認頁點搜尋。
    private func discoverRecentPlaces() async {
        let recentIDs = Set(recentCaptures.prefix(10).map(\.id))
        let unresolved = (personalItems + candidateItems).filter {
            recentIDs.contains($0.captureID) && $0.resolutionStatus != "verified" && $0.discoveryCheckedAt == nil
        }
        guard !unresolved.isEmpty else { return }
        discoveringPlaces = true
        defer { discoveringPlaces = false }
        for item in unresolved.prefix(3) {
            guard !Task.isCancelled else { return }
            do {
                _ = try await inbox.discoverPlaces(for: item.id)
                await loadInbox()
            } catch let error as PlaceDiscoveryError {
                inboxError = error.userMessage
                return
            } catch {
                inboxError = "韓文店名暫時無法查找：\(userMessage(for: error))"
                return
            }
        }
    }

    private func inboxStatus(_ status: String) -> String {
        switch status {
        case "saved", "processing": "正在整理，完成後會出現在下方"
        case "ready": "已整理，可查看來源與候選"
        case "insufficient": "來源已保存，內容不足以辨識地點"
        case "failed": "整理失敗，點此查看並重試"
        default: "已保存"
        }
    }

    private func undoPersonal(_ item: InboxItemRecord) async {
        do { _ = try await inbox.updateItem(item, archived: false); await loadInbox() }
        catch { inboxError = "撤銷失敗：\(userMessage(for: error))" }
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
    let scheduledDay: TripDay?
    let toggleInterest: () -> Void
    let schedule: () -> Void
    let showDay: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
            if let address = entry.addressLabel {
                Text(address).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(SavedRow.status(entry, me: me, scheduledDay: scheduledDay)).font(.caption).foregroundStyle(.secondary)
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
                if entry.saved.status == .saved && canEdit {
                    Button("排進旅程", action: schedule)
                } else if entry.saved.status == .addedToItinerary, scheduledDay != nil {
                    Button("查看第 \((scheduledDay?.displayOrder ?? 0) + 1) 天", action: showDay)
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    static func status(_ entry: SavedEntry, me: UUID?, scheduledDay: TripDay? = nil) -> String {
        var parts = [entry.saved.category.displayName]
        if !entry.isConfirmed {
            parts.append("未定位")
        }
        if let scheduledDay {
            parts.append("已排第 \(scheduledDay.displayOrder + 1) 天")
        } else if entry.saved.status == .addedToItinerary {
            parts.append("已加入行程")
        }
        parts.append(entry.saved.addedBy == nil ? "已刪除帳號的成員新增" : entry.saved.addedBy == me ? "你新增" : "旅伴新增")
        return parts.joined(separator: " · ")
    }
}

/// 收藏詳情：來源、司機卡、當地地圖。
struct SavedDetailView: View {
    let session: SessionModel
    let entry: SavedEntry
    let me: UUID?
    let canEdit: Bool
    let scheduledDay: TripDay?
    let tripCountry: String?
    let repository: TripRepository
    let discoveryRepository: InboxRepository
    let onChanged: () -> Void
    let onOpenDay: (UUID) -> Void
    @State private var addressHint: String?
    @State private var addressSourceURL: String?
    @State private var candidates: [DiscoveredPlace] = []
    @State private var searchingAddress = false
    @State private var addressMessage: String?
    @State private var didSearchAddress = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(entry.title).font(.title3.weight(.semibold))
                    if let address = addressHint ?? entry.addressLabel {
                        Text(entry.isConfirmed ? address : "地址線索：\(address)")
                            .font(.subheadline).textSelection(.enabled)
                    }
                    Text(SavedRow.status(entry, me: me, scheduledDay: scheduledDay))
                        .font(.caption).foregroundStyle(.secondary)
                    if !entry.isConfirmed {
                        Label("未定位，不計入路線", systemImage: "mappin.slash").font(.caption).foregroundStyle(.secondary)
                    }
                    if searchingAddress { ProgressView("正在補查韓文地址…") }
                    if let addressMessage { Text(addressMessage).font(.caption).foregroundStyle(.secondary) }
                }
                if canEdit && entry.saved.status == .saved {
                    Section {
                        NavigationLink {
                            SavedScheduleView(session: session, entry: entry) { dayID in
                                onChanged()
                                onOpenDay(dayID)
                                dismiss()
                            }
                        } label: {
                            Label("排進旅程", systemImage: "calendar.badge.plus")
                        }
                        if !entry.isConfirmed {
                            NavigationLink {
                                ResolvePlaceSheet(session: session, entry: entry, embedded: true) {
                                    onChanged()
                                    dismiss()
                                }
                            } label: {
                                Label("確認地點", systemImage: "mappin.and.ellipse")
                            }
                        }
                    }
                } else if let scheduledDay {
                    Section {
                        Button("查看第 \(scheduledDay.displayOrder + 1) 天") {
                            onOpenDay(scheduledDay.id)
                            dismiss()
                        }
                    }
                }
                if !candidates.isEmpty {
                    Section("可能的店家地址") {
                        ForEach(candidates) { candidate in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(candidate.koreanName ?? candidate.name).font(.subheadline.weight(.semibold))
                                if let address = candidate.addressLocal {
                                    Text(address).font(.caption).textSelection(.enabled)
                                    Button("帶入這個地址") { Task { await accept(candidate) } }
                                        .buttonStyle(.bordered)
                                }
                                LocalMapSearchButtons(name: candidate.searchQuery, countryCode: "KR")
                                if let url = URL(string: candidate.sourceURL), url.scheme == "https" {
                                    Link("查看網頁來源", destination: url).font(.caption)
                                }
                            }
                        }
                    }
                }
                if let source = entry.source, let url = source.url.flatMap(URL.init(string:)) {
                    Section("來源") { Link(url.host ?? url.absoluteString, destination: url) }
                }
                if let source = (addressSourceURL ?? entry.saved.addressSourceURL).flatMap(URL.init(string:)), source.scheme == "https" {
                    Section("地址查找依據") { Link(source.host ?? "查看網頁來源", destination: source) }
                }
                Section {
                    if let place = entry.place {
                        NavigateButton(destination: place.mapPoint, mode: .walking)
                        TaxiCardButton(place: place, fallbackChineseLabel: entry.saved.rawLabel,
                                       fallbackAddress: addressHint ?? entry.saved.addressHint)
                    } else {
                        let country = tripCountry ?? LocalMapCountry.guess(name: entry.saved.rawLabel, timeZone: nil)
                        TaxiCardButton(unlocatedName: entry.saved.rawLabel, countryCode: country,
                                       addressHint: addressHint ?? entry.saved.addressHint)
                        LocalMapSearchButtons(name: [entry.saved.rawLabel, addressHint ?? entry.saved.addressHint].compactMap { $0 }.joined(separator: " "), countryCode: country)
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
            .task { await discoverMissingAddress() }
        }
    }

    private func discoverMissingAddress() async {
        guard !didSearchAddress, canEdit, !entry.isConfirmed, entry.addressLabel == nil,
              (tripCountry ?? LocalMapCountry.guess(name: entry.saved.rawLabel, timeZone: nil)) == "KR" else { return }
        didSearchAddress = true
        searchingAddress = true
        defer { searchingAddress = false }
        do {
            let found = try await discoveryRepository.discoverPlaces(query: entry.saved.rawLabel,
                context: "韓國旅程。\(entry.source?.summary ?? "")")
            let addressed = found.filter { $0.addressLocal != nil }
            if addressed.count == 1, let only = addressed.first {
                await accept(only)
            } else if addressed.isEmpty {
                addressMessage = "目前沒有可核對的地址線索，可稍後再補定位。"
            } else {
                candidates = Array(addressed.prefix(3))
                addressMessage = "有多間可能的店，請核對後選擇地址。"
            }
        } catch let error as PlaceDiscoveryError {
            addressMessage = error.userMessage
        } catch {
            addressMessage = "地址暫時無法查找：\(userMessage(for: error))"
        }
    }

    private func accept(_ candidate: DiscoveredPlace) async {
        guard let address = candidate.addressLocal else { return }
        do {
            let source = URL(string: candidate.sourceURL)?.scheme == "https" ? candidate.sourceURL : nil
            try await repository.setSavedAddressHint(savedID: entry.id, address: address, sourceURL: source)
            addressHint = address
            addressSourceURL = source
            candidates = []
            addressMessage = "已保存地址線索；地圖定位仍待確認。"
            onChanged()
        } catch {
            addressMessage = "地址暫時無法保存：\(userMessage(for: error))"
        }
    }
}

/// 手動補填未確認的地點（AC-04）：搜尋後由使用者選定。
struct ResolvePlaceSheet: View {
    let session: SessionModel
    let entry: SavedEntry
    var embedded = false
    let onDone: () -> Void
    @State private var query = ""
    @State private var results: [PlaceOption] = []
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if embedded {
            content
        } else {
        NavigationStack {
            content
        }
        }
    }

    private var content: some View {
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
                                          matcher: session.routes, placeSearch: session.placeSearch, saveDraft: nil,
                                          discoveryRepository: InboxRepository(client: session.client),
                                          preferredTripID: tripID) { _ in onDone() }
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
                              matcher: session.routes, placeSearch: session.placeSearch, saveDraft: nil,
                              discoveryRepository: InboxRepository(client: session.client),
                              preferredTripID: tripID) { _ in onDone() }
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
