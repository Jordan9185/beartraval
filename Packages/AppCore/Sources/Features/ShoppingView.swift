import AppCore
import PhotosUI
import ShareCore
import SwiftUI

/// Shopping 分頁（規格 §3.6）：想買的商品，與 Saved（地點）分開。
struct ShoppingTab: View {
    let session: SessionModel
    @State private var trips: [Trip] = []
    @State private var tripID: UUID?
    @State private var myRole: TripRole?
    @State private var sync: TripSync?
    @State private var reloadToken = 0
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Group {
                if let tripID {
                    ShoppingListView(service: session.trips, tripID: tripID, canEdit: myRole?.canEdit == true,
                                     queue: session.offlineQueue, reloadToken: reloadToken) { entry in
                        MerchantSearchView(session: session, tripID: tripID, entry: entry) { reloadToken += 1 }
                    }
                } else {
                    ContentUnavailableView("尚未建立行程", systemImage: "bag")
                }
            }
            .navigationTitle("購物清單")
            .toolbar {
                if trips.count > 1 {
                    ToolbarItem(placement: .automatic) {
                        Picker("旅程", selection: $tripID) { ForEach(trips) { Text($0.name).tag(Optional($0.id)) } }
                    }
                }
                if myRole?.canEdit == true {
                    ToolbarItem(placement: .primaryAction) {
                        Button("從貼文或截圖加入", systemImage: "sparkles") { importing = true }
                            .accessibilityIdentifier("importProducts")
                    }
                }
            }
            .sheet(isPresented: $importing) {
                NavigationStack {
                    ProductImportView(content: ShareContent(), repository: session.trips) { _ in
                        importing = false
                        reloadToken += 1
                    }
                    .navigationTitle("從貼文加入")
                    .navigationBarTitleDisplayModeInline()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { importing = false } } }
                }
            }
            .task {
                trips = (try? await session.trips.myTrips()) ?? []
                if tripID == nil { tripID = ShareFlowView.defaultTrip(trips)?.id }
            }
            .onChange(of: tripID, initial: true) { Task { await subscribe() } }
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
public struct ShoppingListView<MerchantScreen: View>: View {
    let service: any ShoppingService
    let tripID: UUID
    let canEdit: Bool
    let queue: OfflineQueue?
    let reloadToken: Int
    let merchantScreen: (ShoppingEntry) -> MerchantScreen

    @State private var entries: [ShoppingEntry] = []
    @State private var newName = ""
    @State private var newPhoto: PhotosPickerItem?
    @State private var newImage: Data?
    @State private var errorMessage: String?
    @State private var loaded = false

    public init(service: any ShoppingService, tripID: UUID, canEdit: Bool, queue: OfflineQueue?, reloadToken: Int,
                @ViewBuilder merchantScreen: @escaping (ShoppingEntry) -> MerchantScreen) {
        self.service = service
        self.tripID = tripID
        self.canEdit = canEdit
        self.queue = queue
        self.reloadToken = reloadToken
        self.merchantScreen = merchantScreen
    }

    public var body: some View {
        List {
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
                            .accessibilityIdentifier("newItemField")
                        Button("新增") { Task { await add() } }
                            .buttonStyle(.borderless)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("addItem")
                    }
                }
            }
            if let errorMessage { ErrorText(errorMessage) }
            ForEach(entries) { entry in
                NavigationLink {
                    ShoppingItemDetailView(service: service, tripID: tripID, entry: entry, canEdit: canEdit,
                                           merchantScreen: canEdit && entry.status == .unscheduled ? AnyView(merchantScreen(entry)) : nil) {
                        Task { await reload() }
                    }
                } label: {
                    ShoppingRow(entry: entry, me: service.currentUserID, canEdit: canEdit, service: service,
                                toggle: { Task { await togglePurchased(entry) } },
                                merchantScreen: { merchantScreen(entry) })
                }
            }
        }
        .overlay {
            if loaded && entries.isEmpty {
                ContentUnavailableView("尚未新增商品", systemImage: "bag", description: canEdit ? Text("在上方輸入想買的東西。") : nil)
            }
        }
        .refreshable { await reload() }
        .task(id: "\(tripID)-\(reloadToken)") { await reload() }
        .onChange(of: newPhoto) {
            Task {
                guard let data = try? await newPhoto?.loadTransferable(type: Data.self) else { return }
                newImage = ImageDownscale.jpeg(from: data)
            }
        }
    }

    private func reload() async {
        if let queue { _ = await queue.flush(using: service as? any QueuedOperationExecutor ?? NoExecutor()) }
        do {
            entries = try await service.shoppingEntries(of: tripID)
            errorMessage = nil
        } catch {
            errorMessage = "讀取失敗：\(userMessage(for: error))"
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

struct ShoppingRow<MerchantScreen: View>: View {
    let entry: ShoppingEntry
    let me: UUID?
    let canEdit: Bool
    let service: any ShoppingService
    let toggle: () -> Void
    let merchantScreen: () -> MerchantScreen

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
                        case .scheduled: Text("已安排：\(entry.plannedDate ?? "") \(entry.plannedStore ?? "")")
                        case .purchased(let by, let at):
                            Text("\(by == nil ? "已刪除帳號的成員" : by == me ? "你" : "旅伴")已購買 · \(at.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .accessibilityIdentifier("status-\(entry.item.name)")
                    Text(" · \(entry.interestedUserIDs.count) 人想買").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            }
        }
    }
}

/// 找可能販售的店（AC-10）：列證據、每間店最佳日 +N 分鐘、「庫存未知」；選店後走 proposal 建立 Purchase Stop。
struct MerchantSearchView: View {
    let session: SessionModel
    let tripID: UUID
    let entry: ShoppingEntry
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("品牌或店名", text: $query).onSubmit { Task { await search() } }
                    Button("搜尋") { Task { await search() } }
                            .buttonStyle(.borderless)
                }
                TextField("官方店鋪查詢頁網址（選填）", text: $officialURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
            } footer: {
                Text("有官方店鋪頁時會作為證據附上；否則標為「地圖搜尋結果」。一律只表示可能販售，庫存未知。")
            }
            if searching { ProgressView("搜尋並計算順路…") }
            ForEach(options) { option in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.place.displayTitle)
                        if let address = option.place.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                        Text("可能販售（\(evidence.displayName)） · 庫存未知").font(.caption).foregroundStyle(.secondary)
                        if let best = option.best, let ins = best.best {
                            Text("最適合 \(dayTitles[best.dayID] ?? "")：路程 +\(ins.addedTravelMinutes ?? 0) 分").font(.caption)
                        } else {
                            Text("無法估算路線").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if option.best?.best != nil {
                        Button("安排在\(dayTitles[option.best!.dayID] ?? "這天")…") { scheduling = option }
                    }
                }
            }
        }
        .navigationTitle(entry.item.name)
        .onAppear { if query.isEmpty { query = entry.item.name; Task { await search() } } }
        .sheet(item: $scheduling) { option in
            ProposalReviewView(session: session, tripID: tripID, dayID: option.best!.dayID, dayTitle: dayTitles[option.best!.dayID] ?? "",
                               mode: option.best!.mode, candidate: SearchResult(draft: option.place.draft), dwellMinutes: 30,
                               shoppingItemID: entry.id) {
                scheduling = nil
                Task {
                    await recordEvidence(option)
                    onScheduled()
                    dismiss()
                }
            }
        }
    }

    private var evidence: MerchantCandidate.EvidenceType {
        officialURL.trimmingCharacters(in: .whitespaces).isEmpty ? .poiCategory : .officialLocator
    }

    private func search() async {
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

    private func recordEvidence(_ option: Option) async {
        guard let place = try? await session.trips.upsertPlace(option.place.draft) else { return }
        let url = officialURL.trimmingCharacters(in: .whitespaces)
        try? await session.trips.addMerchant(itemID: entry.id, placeID: place.id, evidence: evidence,
                                             url: url.isEmpty ? nil : url, note: "Apple 地圖搜尋「\(query)」")
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
