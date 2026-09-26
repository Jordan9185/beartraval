import AppCore
import PhotosUI
import ShareCore
import SwiftUI

/// Shopping 分頁（規格 §3.6）：想買的商品，與 Saved（地點）分開。
struct ShoppingTab: View {
    let session: SessionModel
    private struct ImportRequest: Identifiable {
        let id = UUID()
        let content: ShareContent
    }
    @State private var trips: [Trip] = []
    @State private var tripID: UUID?
    @State private var myRole: TripRole?
    @State private var sync: TripSync?
    @State private var reloadToken = 0
    @State private var importRequest: ImportRequest?
    @State private var personalItems: [InboxItemRecord] = []
    @State private var candidateItems: [InboxItemRecord] = []
    @State private var personalError: String?
    @Environment(\.scenePhase) private var scenePhase

    private var inbox: InboxRepository { InboxRepository(client: session.client) }

    var body: some View {
        NavigationStack {
            Group {
                if let tripID {
                    ShoppingListView(service: session.trips, tripID: tripID, canEdit: myRole?.canEdit == true,
                                     queue: session.offlineQueue, reloadToken: reloadToken,
                                     personalItems: personalItems, candidateItems: candidateItems,
                                     personalRepository: inbox, personalError: personalError,
                                     tripRegionName: trips.first { $0.id == tripID }?.name,
                                     tripCountryCode: trips.first { $0.id == tripID }.flatMap {
                                         LocalMapCountry.guess(name: $0.name, timeZone: $0.timeZone)
                                     },
                                     personalChanged: { Task { await reloadPersonal() } },
                                     onPhotoSelected: { jpeg in
                                         importRequest = ImportRequest(content: ShareContent(hasImage: true, imageJPEG: jpeg))
                                     }) { entry in
                        MerchantSearchView(session: session, tripID: tripID, entry: entry,
                                           regionName: trips.first { $0.id == tripID }?.name ?? "",
                                           regionCountry: trips.first { $0.id == tripID }.flatMap {
                                               LocalMapCountry.guess(name: $0.name, timeZone: $0.timeZone)
                                           }) { reloadToken += 1 }
                    }
                } else {
                    PersonalInboxItemsView(session: session, kind: "product")
                }
            }
            .navigationTitle("購物清單")
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    NavigationLink {
                        PersonalInboxItemsView(session: session, kind: "product")
                    } label: { Label("個人想買", systemImage: "person.crop.circle") }
                }
                if trips.count > 1 {
                    ToolbarItem(placement: .automatic) {
                        Picker("旅程", selection: $tripID) { ForEach(trips) { Text($0.name).tag(Optional($0.id)) } }
                    }
                }
                if myRole?.canEdit == true {
                    ToolbarItem(placement: .primaryAction) {
                        Button("從貼文或截圖加入", systemImage: "sparkles") {
                            importRequest = ImportRequest(content: ShareContent())
                        }
                            .accessibilityIdentifier("importProducts")
                    }
                }
            }
            .sheet(item: $importRequest) { request in
                NavigationStack {
                    ProductImportView(content: request.content, repository: session.trips, discoveryRepository: inbox) { _ in
                        importRequest = nil
                        reloadToken += 1
                    }
                    .navigationTitle("從貼文加入")
                    .navigationBarTitleDisplayModeInline()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { importRequest = nil } } }
                }
            }
            .task {
                trips = (try? await session.trips.myTrips()) ?? []
                if tripID == nil { tripID = ShareFlowView.defaultTrip(trips)?.id }
                await refreshPersonalUntilSettled()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refreshPersonalUntilSettled() } }
            }
            .onChange(of: tripID, initial: true) { Task { await subscribe() } }
        }
    }

    private func reloadPersonal() async {
        do {
            async let personal = inbox.listPersonalItems(kind: "product")
            async let candidates = inbox.listPersonalCandidates(kind: "product")
            (personalItems, candidateItems) = try await (personal, candidates)
            personalError = nil
        } catch { personalError = "分享商品暫時無法讀取：\(userMessage(for: error))" }
    }

    private func refreshPersonalUntilSettled() async {
        await session.syncInboxCaptures()
        for _ in 0..<8 {
            if Task.isCancelled { return }
            await reloadPersonal()
            let captures = (try? await inbox.listCaptures()) ?? []
            let waiting = captures.contains { $0.status == "saved" || $0.status == "processing" }
            if !waiting { return }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// 旅伴購買或新增商品時即時更新（AC-11）。
    private func subscribe() async {
        await sync?.stop()
        sync = nil
        guard let tripID else { return }
        myRole = try? await session.trips.myRole(in: tripID)
        guard let revision = try? await session.trips.tripRevision(tripID) else { return }
        let sync = TripSync(tripID: tripID, repository: session.trips, revision: revision) { events in
            if events.contains(where: { $0.kind.hasPrefix("shopping.") || $0.kind.hasPrefix("day.") }) { reloadToken += 1 }
        }
        self.sync = sync
        await sync.start()
    }
}

/// 商品清單；與後端隔離（`ShoppingService`），UI 測試可用假服務。
/// 注意：這個清單刻意拆成幾個非泛型的小 View（見 `ShoppingGroupSection`）。
/// 泛型套泛型、ForEach 裡再包條件與 Section 時，Release 版在 SwiftUI 建立 view list 會把主執行緒堆疊用光而閃退
/// （2026-09-25 在 iPhone 上重現：儲存第一個附照片的商品後）。
public struct ShoppingListView: View {
    let service: any ShoppingService
    let tripID: UUID
    let canEdit: Bool
    let queue: OfflineQueue?
    let reloadToken: Int
    let personalItems: [InboxItemRecord]
    let candidateItems: [InboxItemRecord]
    let personalRepository: InboxRepository?
    let personalError: String?
    let tripRegionName: String?
    let tripCountryCode: String?
    let personalChanged: () -> Void
    let merchantScreen: (ShoppingEntry) -> AnyView
    /// 快速列選照片後交給完整商品辨識畫面，避免多件商品只取第一件。
    let onPhotoSelected: ((Data) -> Void)?

    @State private var entries: [ShoppingEntry] = []
    @State private var itineraryMatches: [UUID: [ShoppingItineraryMatch]] = [:]
    @State private var itineraryMatchesLoaded = false
    @State private var newName = ""
    @State private var newPhoto: PhotosPickerItem?
    @State private var newImage: Data?
    @State private var errorMessage: String?
    @State private var loaded = false
    @FocusState private var nameFocused: Bool

    public init<MerchantScreen: View>(service: any ShoppingService, tripID: UUID, canEdit: Bool, queue: OfflineQueue?, reloadToken: Int,
                                      personalItems: [InboxItemRecord] = [], candidateItems: [InboxItemRecord] = [],
                                      personalRepository: InboxRepository? = nil, personalError: String? = nil,
                                      tripRegionName: String? = nil, tripCountryCode: String? = nil,
                                      personalChanged: @escaping () -> Void = {},
                                      onPhotoSelected: ((Data) -> Void)? = nil,
                                      @ViewBuilder merchantScreen: @escaping (ShoppingEntry) -> MerchantScreen) {
        self.service = service
        self.tripID = tripID
        self.canEdit = canEdit
        self.queue = queue
        self.reloadToken = reloadToken
        self.personalItems = personalItems
        self.candidateItems = candidateItems
        self.personalRepository = personalRepository
        self.personalError = personalError
        self.tripRegionName = tripRegionName
        self.tripCountryCode = tripCountryCode
        self.personalChanged = personalChanged
        self.onPhotoSelected = onPhotoSelected
        self.merchantScreen = { AnyView(merchantScreen($0)) }
    }

    private var rowContext: ShoppingRowContext {
        ShoppingRowContext(service: service, tripID: tripID, canEdit: canEdit, merchantScreen: merchantScreen,
                           itineraryMatches: itineraryMatches, itineraryMatchesLoaded: itineraryMatchesLoaded,
                           toggle: { entry in Task { await togglePurchased(entry) } },
                           changed: { Task { await reload() } })
    }

    public var body: some View {
        List {
            if let personalError { ErrorText(personalError) }
            if let personalRepository, !personalItems.isEmpty {
                Section("我的想買") {
                    ForEach(personalItems) { item in
                        PersonalInboxRow(item: item, kind: "product", repository: personalRepository,
                                         tripRegionName: tripRegionName, tripCountryCode: tripCountryCode) { _ in personalChanged() }
                    }
                }
            }
            if let personalRepository, !candidateItems.isEmpty {
                Section("待確認的商品") {
                    ForEach(candidateItems) { item in
                        PersonalInboxRow(item: item, kind: "product", repository: personalRepository, candidate: true) { _ in personalChanged() }
                    }
                }
            }
            let progress = ShoppingProgress(entries)
            if progress.total > 0 {
                Section {
                    ProgressView(value: Double(progress.purchased), total: Double(progress.total)) {
                        Text("已買 \(progress.purchased)／\(progress.total)").accessibilityIdentifier("shoppingProgress")
                    }
                }
            }
            if canEdit {
                Section {
                    HStack {
                        PhotosPicker(selection: $newPhoto, matching: .images) {
                            Image(systemName: newImage == nil ? "camera" : "photo.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(newImage == nil ? "附上照片" : "已附照片")
                        TextField("新增想買的商品", text: $newName).onSubmit { Task { await add() } }
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .accessibilityIdentifier("newItemField")
                        Button("新增") { Task { await add() } }
                            .buttonStyle(.borderless)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("addItem")
                    }
                } footer: {
                    if onPhotoSelected != nil { Text("選照片會辨識所有商品與店家線索，再讓你確認要加入哪些。") }
                }
            }
            if let errorMessage { ErrorText(errorMessage) }
            // 依狀態分組：未安排、已安排、已購買（每列不必再靠顏色分辨）。
            ShoppingGroupSection(group: .unscheduled, entries: entries, context: rowContext)
            ShoppingGroupSection(group: .scheduled, entries: entries, context: rowContext)
            ShoppingGroupSection(group: .purchased, entries: entries, context: rowContext)
        }
        .overlay {
            if loaded && entries.isEmpty && personalItems.isEmpty && candidateItems.isEmpty {
                ContentUnavailableView("還沒有想買的東西", systemImage: "bag", description: canEdit ? Text("在上方輸入，或從貼文、截圖加入。") : nil)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { nameFocused = false }
            }
        }
        .refreshable { await reload() }
        .task(id: "\(tripID)-\(reloadToken)") { await reload() }
        .onChange(of: newPhoto) {
            Task {
                guard let data = try? await newPhoto?.loadTransferable(type: Data.self) else { return }
                guard let jpeg = ImageDownscale.jpeg(from: data, maxPixel: 2048) else { return }
                if let onPhotoSelected {
                    newPhoto = nil
                    onPhotoSelected(jpeg)
                } else {
                    newImage = jpeg
                }
            }
        }
    }

    private func reload() async {
        if let queue { _ = await queue.flush(using: service as? any QueuedOperationExecutor ?? NoExecutor()) }
        do {
            entries = try await service.shoppingEntries(of: tripID)
            errorMessage = nil
            do {
                itineraryMatches = try await service.itineraryMatches(tripID: tripID, items: entries.map(\.item))
                itineraryMatchesLoaded = true
            } catch {
                itineraryMatches = [:]
                itineraryMatchesLoaded = false
                errorMessage = "行程內販售地點暫時無法讀取：\(userMessage(for: error))"
            }
        } catch {
            errorMessage = "讀取失敗：\(userMessage(for: error))"
            itineraryMatchesLoaded = false
        }
        loaded = true
    }

    private func add() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let item = try await service.addShoppingItem(tripID: tripID, name: name, note: nil, url: nil, clientOpID: UUID())
            if let newImage { try await service.setShoppingImage(tripID: tripID, itemID: item.id, jpeg: newImage) }
            newName = ""
            newImage = nil
            newPhoto = nil
            await reload()
        } catch {
            errorMessage = "新增失敗：\(userMessage(for: error))"
        }
    }

    /// 勾選購買可離線（決策 D6）；撤銷僅限購買者或 Owner，由伺服器判定。
    private func togglePurchased(_ entry: ShoppingEntry) async {
        let purchase = !entry.isPurchased
        do {
            try await service.recordPurchase(itemID: entry.id, purchased: purchase, clientOpID: UUID())
            await reload()
        } catch BackendError.other {
            if let queue { await queue.enqueue(.recordPurchase(itemID: entry.id, purchased: purchase)) }
            errorMessage = "目前離線，已排入佇列，連線後送出。"
        } catch BackendError.forbidden {
            errorMessage = "只有購買者或擁有者可以撤銷。"
        } catch {
            errorMessage = "更新失敗：\(userMessage(for: error))"
        }
    }
}

private struct NoExecutor: QueuedOperationExecutor {
    func execute(_ item: QueuedItem) async throws {}
}

/// 清單列需要的共用資料（避免每列都帶一串參數與泛型）。
struct ShoppingRowContext {
    let service: any ShoppingService
    let tripID: UUID
    let canEdit: Bool
    let merchantScreen: (ShoppingEntry) -> AnyView
    let itineraryMatches: [UUID: [ShoppingItineraryMatch]]
    let itineraryMatchesLoaded: Bool
    let toggle: (ShoppingEntry) -> Void
    let changed: () -> Void
}

/// 一個狀態分組；沒有項目時什麼都不顯示。
struct ShoppingGroupSection: View {
    let group: ShoppingGroup
    let entries: [ShoppingEntry]
    let context: ShoppingRowContext

    var body: some View {
        let members = entries.filter { group.contains($0) }
        if !members.isEmpty {
            Section(group.title) {
                ForEach(members) { entry in
                    ShoppingEntryLink(entry: entry, context: context)
                }
            }
        }
    }
}

struct ShoppingEntryLink: View {
    let entry: ShoppingEntry
    let context: ShoppingRowContext

    var body: some View {
        NavigationLink {
            ShoppingItemDetailView(service: context.service, tripID: context.tripID, entry: entry, canEdit: context.canEdit,
                                   merchantScreen: context.canEdit && entry.status == .unscheduled ? context.merchantScreen(entry) : nil,
                                   itineraryMatches: context.itineraryMatches[entry.id] ?? [],
                                   itineraryMatchesLoaded: context.itineraryMatchesLoaded,
                                   onChanged: context.changed)
        } label: {
            ShoppingRow(entry: entry, me: context.service.currentUserID, canEdit: context.canEdit, service: context.service,
                        itineraryMatches: context.itineraryMatches[entry.id] ?? [],
                        itineraryMatchesLoaded: context.itineraryMatchesLoaded,
                        toggle: { context.toggle(entry) })
        }
    }
}

struct ShoppingRow: View {
    let entry: ShoppingEntry
    let me: UUID?
    let canEdit: Bool
    let service: any ShoppingService
    let itineraryMatches: [ShoppingItineraryMatch]
    let itineraryMatchesLoaded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            if let path = entry.item.imagePath {
                ShoppingImage(path: path, service: service).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Button(action: toggle) {
                Image(systemName: entry.isPurchased ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(entry.isPurchased ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canEdit)
            .accessibilityIdentifier("purchase-\(entry.item.name)")
            .accessibilityLabel(entry.isPurchased ? "撤銷已購買" : "標記已購買")

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.name).strikethrough(entry.isPurchased)
                // 一行狀態：狀態 · 想買人數。
                HStack(spacing: 0) {
                    Group {
                        switch entry.status {
                        case .unscheduled: Text("未安排")
                        case .scheduled:
                            Text("已安排：" + [entry.plannedDayNumber.map { "第 \($0) 天" } ?? entry.plannedDate, entry.plannedStore]
                                .compactMap { $0 }.joined(separator: " · "))
                        case .purchased(let by, let at):
                            Text("\(by == nil ? "已刪除帳號的成員" : by == me ? "你" : "旅伴")已購買 · \(at.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .accessibilityIdentifier("status-\(entry.item.name)")
                    Text(" · \(entry.interestedUserIDs.count) 人想買").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let first = itineraryMatches.first {
                    Text("行程第 \(first.dayNumber) 天 · \(first.placeName)\(itineraryMatches.count > 1 ? " 等 \(itineraryMatches.count) 處" : "") · \(first.evidenceType == nil ? "可詢問" : "可能販售")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityIdentifier("tripMerchant-\(entry.item.name)")
                } else if itineraryMatchesLoaded && entry.status == .unscheduled {
                    Text("行程內尚無販售線索").font(.caption).foregroundStyle(.secondary)
                }

            }
        }
    }
}

/// 找可能販售的店（AC-10）：列證據、每間店最佳日 +N 分鐘、「庫存未知」；選店後走 proposal 建立 Purchase Stop。
struct MerchantSearchView: View {
    let session: SessionModel
    let tripID: UUID
    let entry: ShoppingEntry
    let regionName: String
    let regionCountry: String?
    let onScheduled: () -> Void

    struct Option: Identifiable {
        let place: PlaceOption
        var best: DayMatch?
        var id: String { place.id }
    }

    @State private var query = ""
    @State private var officialURL = ""
    @State private var options: [Option] = []
    @State private var searching = false
    @State private var dayTitles: [UUID: String] = [:]
    @State private var scheduling: Option?
    @State private var errorMessage: String?
    @State private var selectedResearch: DiscoveredPlace?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("AI 查找的實體店候選") {
                ProductStoreSuggestionsView(repository: InboxRepository(client: session.client),
                                            productName: entry.item.name, storeHint: entry.item.storeHint,
                                            region: regionName, countryCode: regionCountry) { candidate in
                    selectedResearch = candidate
                    query = candidate.koreanName ?? candidate.name
                    Task { await search() }
                }
            }
            Section {
                PlaceSearchField(text: $query, placeholder: "品牌或店名", isSearching: searching) { Task { await search() } }
                TextField("官方店鋪查詢頁網址（選填）", text: $officialURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
            } footer: {
                Text("AI 店家有網頁來源，但不代表這件商品有賣；地圖只供定位。安排前請核對店面，庫存一律未知。")
            }
            if let errorMessage { ErrorText(errorMessage) }
            if searching { ProgressView("搜尋並計算順路…") }
            ForEach(options) { option in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.place.displayTitle)
                        if let address = option.place.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                        Text("店面線索 · 商品販售與庫存待詢問")
                            .font(.caption).foregroundStyle(.secondary)
                        if let best = option.best, let ins = best.best {
                            Text("最適合 \(dayTitles[best.dayID] ?? "")：路程 +\(ins.addedTravelMinutes ?? 0) 分").font(.caption)
                        } else {
                            Text("無法估算路線").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if option.best?.best != nil {
                        Button("安排在\(dayTitles[option.best!.dayID] ?? "這天")…") {
                            // 有官方來源才記錄販售候選；地圖與一般店面線索只供使用者安排詢問。
                            Task { if await recordEvidence(option) { scheduling = option } }
                        }
                    }
                }
            }
        }
        .navigationTitle(entry.item.name)
        .onAppear { if query.isEmpty { query = entry.item.storeHint ?? "" } }
        .sheet(item: $scheduling) { option in
            ProposalReviewView(session: session, tripID: tripID, dayID: option.best!.dayID, dayTitle: dayTitles[option.best!.dayID] ?? "",
                               mode: option.best!.mode, candidate: SearchResult(draft: option.place.draft), dwellMinutes: 30,
                               shoppingItemID: entry.id) {
                scheduling = nil
                onScheduled()
                dismiss()
            }
        }
    }

    private func search() async {
        if let selectedResearch, query != (selectedResearch.koreanName ?? selectedResearch.name) {
            self.selectedResearch = nil
        }
        searching = true
        defer { searching = false }
        let found = await session.placeSearch.search(query, in: await session.trips.searchAreas(of: tripID), limit: 5)
        guard let days = try? await session.trips.days(of: tripID) else { return }
        for day in days { dayTitles[day.id] = "第 \(day.displayOrder + 1) 天" }
        var computed: [Option] = []
        for place in found {
            var matches: [DayMatch] = []
            for day in days {
                guard let plan = try? await session.trips.loadDayPlan(tripID: tripID, dayID: day.id) else { continue }
                let point = RoutePoint(coordinate: Coordinate(latitude: place.draft.latitude, longitude: place.draft.longitude),
                                       countryCode: place.draft.countryCode)
                matches.append(await session.routes.match(RouteCandidate(point: point, dwellMinutes: 30), into: plan, mode: day.transportMode))
            }
            computed.append(Option(place: place, best: RouteMatcher.bestDay(matches)))
        }
        // 依 detour 排序；無法估算的排最後。
        options = computed.sorted { ($0.best?.best?.addedTravelMinutes ?? .max) < ($1.best?.best?.addedTravelMinutes ?? .max) }
    }

    private func recordEvidence(_ option: Option) async -> Bool {
        let url = officialURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return true }
        do {
            let place = try await session.trips.upsertPlace(option.place.draft)
            try await session.trips.addMerchant(itemID: entry.id, placeID: place.id, evidence: .officialLocator,
                                                url: url, note: "官方店鋪來源；商品是否販售及庫存待確認。")
            errorMessage = nil
            return true
        } catch {
            errorMessage = "無法記錄販售店：\(userMessage(for: error))"
            return false
        }
    }
}

/// 私有 bucket 的商品照片（簽名網址）。
struct ShoppingImage: View {
    let path: String
    let service: any ShoppingService
    var contentMode: ContentMode = .fill
    @State private var url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: contentMode)
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .task(id: path) { url = await service.shoppingImageURL(path: path) }
    }
}

/// 商品詳情：照片、來源、到社群找這個商品、換照片。
struct ShoppingItemDetailView: View {
    let service: any ShoppingService
    let tripID: UUID
    let entry: ShoppingEntry
    let canEdit: Bool
    var merchantScreen: AnyView? = nil
    var itineraryMatches: [ShoppingItineraryMatch] = []
    var itineraryMatchesLoaded = false
    let onChanged: () -> Void
    @State private var photo: PhotosPickerItem?
    @State private var uploading = false
    @State private var errorMessage: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            if let path = entry.item.imagePath {
                Section {
                    ShoppingImage(path: path, service: service, contentMode: .fit)
                        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 360)
                }
            }
            Section {
                Text(entry.item.name).font(.title3.weight(.semibold))
                if let note = entry.item.note { Text(note) }
                if let link = entry.item.url.flatMap(URL.init(string:)) {
                    Link(link.host ?? link.absoluteString, destination: link)
                }
                if canEdit {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label(uploading ? "上傳中…" : entry.item.imagePath == nil ? "附上照片" : "換照片", systemImage: "photo")
                    }
                    .disabled(uploading)
                }
                if let errorMessage { ErrorText(errorMessage) }
            }
            if let merchantScreen {
                Section {
                    NavigationLink("找可能販售的店…") { merchantScreen }
                        .accessibilityIdentifier("findMerchants")
                }
            }
            if itineraryMatchesLoaded && !entry.isPurchased {
                Section {
                    if itineraryMatches.isEmpty {
                        Text("目前沒有與行程地點相符、且尚未過期的販售線索。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(itineraryMatches) { match in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(match.dayNumber) 天 · \(match.placeName)")
                            Text(match.evidenceType.map { "可能販售（\($0.displayName)） · 庫存未知" }
                                 ?? (match.evidenceNote == nil ? "店名與商品名稱相符，尚未查證是否販售 · 庫存未知"
                                     : "分享提到的店名與行程相符，尚未查證是否販售 · 庫存未知"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let note = match.evidenceNote, !note.isEmpty {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                            if let source = match.evidenceURL.flatMap(URL.init(string:)),
                               ["https", "http"].contains(source.scheme?.lowercased() ?? "") {
                                Link("查看販售線索", destination: source).font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("行程中可確認的地點")
                } footer: {
                    Text("只比對已確認的行程地點；店名相符是待確認建議，販售線索也可能變動。出發前請向店家確認是否販售與庫存。")
                }
            }
            Section {
                ForEach(ProductSearchLinks.links(for: entry.item.name), id: \.self) { link in
                    Button("在 \(link.title) 搜尋", systemImage: "magnifyingglass") { openURL(link.url) }
                }
            } header: {
                Text("找找看")
            } footer: {
                Text("看別人的開箱、在哪裡買得到。是否有賣、有沒有庫存以店家為準。")
            }
        }
        .navigationTitle("商品")
        .navigationBarTitleDisplayModeInline()
        .onChange(of: photo) {
            Task {
                guard let data = try? await photo?.loadTransferable(type: Data.self), let jpeg = ImageDownscale.jpeg(from: data) else { return }
                uploading = true
                defer { uploading = false }
                do {
                    try await service.setShoppingImage(tripID: tripID, itemID: entry.id, jpeg: jpeg)
                    onChanged()
                } catch {
                    errorMessage = "上傳失敗：\(userMessage(for: error))"
                }
            }
        }
    }
}

enum ShoppingGroup: CaseIterable {
    case unscheduled, scheduled, purchased

    var title: String {
        switch self {
        case .unscheduled: "未安排"
        case .scheduled: "已安排"
        case .purchased: "已購買"
        }
    }

    func contains(_ entry: ShoppingEntry) -> Bool {
        switch (self, entry.status) {
        case (.unscheduled, .unscheduled), (.scheduled, .scheduled), (.purchased, .purchased): true
        default: false
        }
    }
}
