import AppCore
import ShareCore
import SwiftUI

/// 分享後的處理紀錄；已歸檔的結果也可從個人收藏／購物查看。
struct InboxView: View {
    let session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var local: [InboxCapture] = []
    @State private var remote: [InboxRecord] = []
    @State private var errorMessage: String?
    @State private var loading = true

    private var repository: InboxRepository { InboxRepository(client: session.client) }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage { ErrorText(errorMessage) }
                if !local.isEmpty {
                    Section("此裝置保存的內容") {
                        ForEach(local) { capture in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(capture.title ?? capture.urls.first?.host ?? capture.texts.first?.prefix(50).description ?? "分享內容")
                                    .lineLimit(2)
                                Text(localStatus(capture)).font(.caption).foregroundStyle(.secondary)
                                if capture.ownerHint == nil {
                                    Button("匯入目前帳號") { Task { await claim(capture) } }
                                } else if capture.syncedRemoteID == nil {
                                    Button("重試同步") { Task { await syncAndReload() } }
                                }
                            }
                        }
                    }
                }
                Section("分享紀錄") {
                    ForEach(remote) { record in
                        NavigationLink {
                            InboxDetailView(record: record, repository: repository)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title ?? record.sourceURL.flatMap { URL(string: $0)?.host } ??
                                     String(record.rawText.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines))
                                    .lineLimit(2)
                                HStack {
                                    Text(statusTitle(record.status))
                                    Text(String(record.lastSharedAt.prefix(10)))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !loading && remote.isEmpty && local.isEmpty {
                        ContentUnavailableView("還沒有分享內容", systemImage: "tray",
                                               description: Text("在社群或相簿選「分享 → BeaRTravel」，內容會先收下再整理。"))
                    }
                }
            }
            .navigationTitle("分享收件匣")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
            .refreshable { await reload() }
            .task { await syncAndReload() }
        }
    }

    private func localStatus(_ capture: InboxCapture) -> String {
        if capture.ownerHint == nil { return "尚未指定帳號；確認後才會上傳" }
        if capture.assets.contains(where: \.isVideo) {
            return capture.syncedRemoteID == nil
                ? "影片已保存在此裝置；等待同步來源資訊"
                : "來源已同步；影片原檔保存在此裝置，畫面辨識仍待驗證"
        }
        return "等待網路同步與自動整理"
    }

    private func statusTitle(_ status: String) -> String {
        switch status {
        case "saved": "已同步，等待整理"
        case "processing": "正在整理"
        case "ready": "已整理"
        case "insufficient": "資訊不足，已保存來源"
        case "failed": "整理失敗，可重試"
        default: "已保存"
        }
    }

    private func reload() async {
        let me = session.trips.currentUserID
        local = (InboxCaptureStore.shared()?.all() ?? []).filter { $0.ownerHint == nil || $0.ownerHint == me }
        do { remote = try await repository.listCaptures(); errorMessage = nil }
        catch { errorMessage = "讀取失敗：\(error.localizedDescription)" }
        loading = false
    }

    private func syncAndReload() async {
        local = (InboxCaptureStore.shared()?.all() ?? []).filter { $0.ownerHint == nil || $0.ownerHint == session.trips.currentUserID }
        await session.syncInboxCaptures()
        await session.resolveInboxPlaces()
        await reload()
    }

    private func claim(_ capture: InboxCapture) async {
        guard let me = session.trips.currentUserID, let store = InboxCaptureStore.shared() else { return }
        do {
            try store.claim(capture, for: me)
            await syncAndReload()
        } catch { errorMessage = "匯入失敗：\(error.localizedDescription)" }
    }
}

private struct InboxDetailView: View {
    let record: InboxRecord
    let repository: InboxRepository
    @State private var items: [InboxItemRecord] = []
    @State private var templates: [InboxTemplateRecord] = []
    @State private var editing: InboxItemRecord?
    @State private var resolving: InboxItemRecord?
    @State private var publishing: InboxItemRecord?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage { ErrorText(errorMessage) }
            Section("來源") {
                if record.unavailableCount > 0 {
                    Text("有 \(record.unavailableCount) 份附件無法取得；以下整理只依實際收到的內容。")
                        .foregroundStyle(.secondary)
                }
                if let urlText = record.sourceURL, let url = URL(string: urlText) {
                    Link(url.host ?? "開啟來源", destination: url)
                }
                if let title = record.title { Text(title) }
                if !record.rawText.isEmpty { Text(record.rawText).textSelection(.enabled) }
                if record.rawText.isEmpty, record.sourceURL != nil {
                    Text("只有連結時無法讀到影片畫面或貼文內文，地點不會憑網址猜測。")
                        .foregroundStyle(.secondary)
                }
            }
            if !items.isEmpty {
                Section("辨識結果") {
                    ForEach(items) { item in
                        InboxItemRow(item: item, edit: { editing = item },
                                     resolve: { resolving = item }, publish: { publishing = item },
                                     toggle: { Task { await toggle(item) } })
                    }
                }
            }
            if !templates.isEmpty {
                Section("行程模板") {
                    ForEach(templates) { template in
                        NavigationLink(template.title) { InboxTemplateEditor(template: template, repository: repository) }
                    }
                }
            }
            if record.status == "insufficient" {
                Section { Text("資訊不足，來源已保留。可以稍後分享截圖或影片檔補充。") }
            }
            if record.status == "failed" {
                Section {
                    Text("整理失敗：\(record.errorCode ?? "服務暫時無法使用")")
                    Button("重新整理") { Task { await retry() } }
                }
            }
        }
        .navigationTitle("分享內容")
        .sheet(item: $editing) { item in
            InboxItemEditor(item: item) { name in
                do {
                    let updated = try await repository.updateItem(item, name: name)
                    replace(updated)
                    editing = nil
                } catch { errorMessage = "更正失敗：\(error.localizedDescription)" }
            }
        }
        .sheet(item: $resolving) { item in
            InboxPlaceResolveView(item: item, repository: repository) { updated in
                replace(updated)
                resolving = nil
            }
        }
        .sheet(item: $publishing) { item in
            InboxPublishView(item: item, repository: repository) { publishing = nil }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            items = try await repository.listItems(captureID: record.id)
            templates = try await repository.listTemplates(captureID: record.id)
            errorMessage = nil
        } catch { errorMessage = "讀取結果失敗：\(error.localizedDescription)" }
    }

    private func toggle(_ item: InboxItemRecord) async {
        do { replace(try await repository.updateItem(item, archived: !item.archived)) }
        catch { errorMessage = "更新失敗：\(error.localizedDescription)" }
    }

    private func replace(_ item: InboxItemRecord) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
    }

    private func retry() async {
        do { try await repository.requestAnalysis(captureID: record.id); errorMessage = nil }
        catch { errorMessage = "重試失敗：\(error.localizedDescription)" }
    }
}

private struct InboxItemRow: View {
    let item: InboxItemRecord
    let edit: () -> Void
    let resolve: () -> Void
    let publish: () -> Void
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.displayName)
                Spacer()
                Text(item.kind == "product" ? "想買" : "想去")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("來源：\(item.sourceSpan)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            if item.kind == "place" && item.resolutionStatus != "verified" {
                Text("地點未定位，暫不計算路線").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("更正", action: edit)
                if item.kind == "place" && item.resolutionStatus != "verified" {
                    Button("確認地點", action: resolve)
                }
                Button("加入旅伴清單", action: publish)
                Button(item.archived ? "撤銷收藏" : "加入個人清單", action: toggle)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

private struct InboxPublishView: View {
    let item: InboxItemRecord
    let repository: InboxRepository
    let onPublished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var trips: [Trip] = []
    @State private var selectedTripID: UUID?
    @State private var sourceURL: String?
    @State private var operationID = UUID()
    @State private var publishing = false
    @State private var errorMessage: String?

    private var tripRepository: TripRepository { TripRepository(client: repository.client) }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage { ErrorText(errorMessage) }
                Section("項目") {
                    Text(item.displayName)
                    if item.kind == "place", item.placeID == nil {
                        Text("這間店還沒定位，加入共同收藏後也不能用來計算路線。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("要給哪個旅程的旅伴看") {
                    Picker("旅程", selection: $selectedTripID) {
                        Text("選擇旅程").tag(UUID?.none)
                        ForEach(trips) { trip in Text(trip.name).tag(Optional(trip.id)) }
                    }
                    if trips.isEmpty { Text("目前沒有可編輯的旅程。") }
                }
                Section {
                    Button(publishing ? "加入中…" : "確認加入共同\(item.kind == "product" ? "購物" : "收藏")") {
                        Task { await publish() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTripID == nil || publishing)
                }
            }
            .navigationTitle("分享給旅伴")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            trips = try await tripRepository.editableTrips()
            sourceURL = try await repository.capture(id: item.captureID)?.sourceURL
            if trips.count == 1 { selectedTripID = trips[0].id }
        } catch { errorMessage = "讀取旅程失敗：\(error.localizedDescription)" }
    }

    private func publish() async {
        guard let selectedTripID else { return }
        publishing = true
        defer { publishing = false }
        do {
            if item.kind == "product" {
                _ = try await tripRepository.addShoppingItem(tripID: selectedTripID, name: item.displayName,
                    note: "來自分享：\(item.sourceSpan)", url: sourceURL, clientOpID: operationID)
            } else {
                // 同一篇可能有多間店；來源保留 URL，但不以單一 canonical URL 把不同店誤合併。
                let source = SavedSource(type: "share", url: sourceURL, canonicalUrl: nil, summary: item.sourceSpan)
                _ = try await tripRepository.savePlace(tripID: selectedTripID, label: item.displayName,
                    category: .place, placeID: item.placeID, source: source, clientOpID: operationID)
            }
            onPublished()
        } catch { errorMessage = "加入失敗：\(error.localizedDescription)" }
    }
}

private struct InboxPlaceResolveView: View {
    let item: InboxItemRecord
    let repository: InboxRepository
    let onConfirmed: (InboxItemRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var candidates: [PlaceOption] = []
    @State private var searching = false
    @State private var saving = false
    @State private var errorMessage: String?

    init(item: InboxItemRecord, repository: InboxRepository, onConfirmed: @escaping (InboxItemRecord) -> Void) {
        self.item = item
        self.repository = repository
        self.onConfirmed = onConfirmed
        _query = State(initialValue: item.displayName)
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage { ErrorText(errorMessage) }
                Section("搜尋店家") {
                    TextField("店名或地址", text: $query)
                    Button("搜尋") { Task { await search() } }.disabled(query.isEmpty || searching)
                    if searching { ProgressView("搜尋中…") }
                }
                Section("地圖候選") {
                    ForEach(candidates) { option in
                        Button {
                            Task { await confirm(option) }
                        } label: {
                            PlaceOptionRow(title: option.name, address: option.address)
                        }
                        .disabled(saving)
                    }
                    if !searching && candidates.isEmpty {
                        Text("沒有可確認的地點；可保留在個人收藏，稍後再搜尋。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("確認地點")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
            .task { await search() }
        }
    }

    private func search() async {
        searching = true
        defer { searching = false }
        switch await MapKitPlaceSearch().lookup(query, around: nil, limit: 8) {
        case .found(let options): candidates = options; errorMessage = nil
        case .notFound: candidates = []; errorMessage = nil
        case .unavailable: candidates = []; errorMessage = "地圖暫時無法搜尋，請稍後再試。"
        }
    }

    private func confirm(_ option: PlaceOption) async {
        saving = true
        defer { saving = false }
        do {
            let place = try await TripRepository(client: repository.client).upsertPlace(option.draft)
            let updated = try await repository.confirmPlace(item, placeID: place.id)
            onConfirmed(updated)
        } catch { errorMessage = "確認失敗：\(error.localizedDescription)" }
    }
}

private struct InboxItemEditor: View {
    let item: InboxItemRecord
    let save: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(item: InboxItemRecord, save: @escaping (String) async -> Void) {
        self.item = item
        self.save = save
        _name = State(initialValue: item.displayName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名稱", text: $name)
                Text("來源：\(item.sourceSpan)").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("更正項目")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { Task { await save(name.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct InboxTemplateEditor: View {
    let repository: InboxRepository
    @State private var template: InboxTemplateRecord
    @State private var title: String
    @State private var draft: InboxTemplateDraft
    @State private var errorMessage: String?
    @State private var saved = true

    init(template: InboxTemplateRecord, repository: InboxRepository) {
        self.repository = repository
        _template = State(initialValue: template)
        _title = State(initialValue: template.title)
        _draft = State(initialValue: template.draft)
    }

    var body: some View {
        List {
            if let errorMessage { ErrorText(errorMessage) }
            Section("模板名稱") { TextField("名稱", text: $title) }
            ForEach(draft.days.indices, id: \.self) { index in
                InboxTemplateDaySection(day: $draft.days[index])
            }
            Section {
                Button("新增一天") {
                    draft.days.append(InboxTemplateDay(dayIndex: draft.days.count + 1, sourceSpan: "使用者新增", stops: []))
                }
            } footer: {
                Text("這是可編輯草稿。他人的訂位不會變成你的固定行程；目前不會直接改動正式旅程。")
            }
            Section {
                NavigationLink("預覽並套用到旅程") {
                    InboxTemplateApplyView(template: template, repository: repository)
                }
                .disabled(!saved || draft.days.isEmpty)
            }
        }
        .navigationTitle("調整行程模板")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saved ? "已儲存" : "儲存") { Task { await save() } }
                    .disabled(saved || title.trimmingCharacters(in: .whitespaces).isEmpty ||
                              draft.days.flatMap(\.stops).contains { $0.label.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .onChange(of: title) { saved = false }
        .onChange(of: draft) { saved = false }
    }

    private func save() async {
        do {
            template = try await repository.updateTemplate(template, title: title, draft: draft)
            saved = true
            errorMessage = nil
        } catch { errorMessage = "儲存失敗：\(error.localizedDescription)" }
    }
}

private struct InboxTemplateDaySection: View {
    @Binding var day: InboxTemplateDay

    var body: some View {
        Section(day.dayIndex.map { "第 \($0) 天" } ?? "未分天") {
            Stepper("安排在第 \(day.dayIndex ?? 1) 天", value: Binding(
                get: { day.dayIndex ?? 1 }, set: { day.dayIndex = $0 }
            ), in: 1...30)
            ForEach($day.stops) { $stop in
                VStack(alignment: .leading) {
                    TextField("地點或活動", text: $stop.label)
                    Text("來源：\(stop.sourceSpan)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { day.stops.remove(atOffsets: $0) }
            .onMove { day.stops.move(fromOffsets: $0, toOffset: $1) }
            Button("新增項目") {
                day.stops.append(InboxTemplateStop(label: "", sourceSpan: "使用者新增", originType: "explicit"))
            }
        }
    }
}

/// 套用前只預覽；所有新增地點先是未定位文字，路線分鐘數維持未知。
private struct InboxTemplateApplyView: View {
    let template: InboxTemplateRecord
    let repository: InboxRepository
    @State private var trips: [Trip] = []
    @State private var selectedTripID: UUID?
    @State private var days: [TripDay] = []
    @State private var existingStops: [Stop] = []
    @State private var startDate = Date()
    @State private var timeZoneID = "Asia/Seoul"
    @State private var operationID = UUID()
    @State private var completedTripID: UUID?
    @State private var errorMessage: String?
    @State private var submitting = false

    private var tripRepository: TripRepository { TripRepository(client: repository.client) }
    private var maxDay: Int { template.draft.days.compactMap(\.dayIndex).max() ?? 0 }
    private var assigned: Bool {
        let numbers = template.draft.days.compactMap(\.dayIndex)
        return numbers.count == template.draft.days.count && Set(numbers).count == numbers.count && maxDay > 0 &&
            template.draft.days.contains { !$0.stops.isEmpty }
    }

    var body: some View {
        List {
            if let errorMessage { ErrorText(errorMessage) }
            if let completedTripID {
                Section {
                    Label("已套用到旅程", systemImage: "checkmark.circle")
                    Text("新增地點仍待定位；確認地點後才能計算路線。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("旅程 ID：\(completedTripID.uuidString)").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("套用目標") {
                    Picker("旅程", selection: $selectedTripID) {
                        Text("建立新旅程").tag(UUID?.none)
                        ForEach(trips) { trip in Text(trip.name).tag(Optional(trip.id)) }
                    }
                    if selectedTripID == nil {
                        DatePicker("開始日期", selection: $startDate, displayedComponents: .date)
                        Picker("時區", selection: $timeZoneID) {
                            ForEach(TripTimeZones.common, id: \.self) { id in
                                Text(TripTimeZones.displayName(id)).tag(id)
                            }
                        }
                        Text("會建立 \(maxDay) 天的新旅程，日期與時區由你決定。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let trip = trips.first(where: { $0.id == selectedTripID }) {
                        Text("既有旅程：\(trip.startDate) ～ \(trip.endDate)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("新增預覽") {
                    ForEach(template.draft.days.indices, id: \.self) { index in
                        let day = template.draft.days[index]
                        VStack(alignment: .leading, spacing: 5) {
                            Text(day.dayIndex.map { "第 \($0) 天" } ?? "未分天").font(.headline)
                            ForEach(day.stops) { stop in
                                Text("＋ \(stop.label)")
                            }
                        }
                    }
                    Text("所有新增地點先標記待定位；沒有可查的路線時不顯示順路分鐘。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if selectedTripID != nil {
                    Section("既有行程") {
                        Text("固定行程 \(existingStops.filter(\.fixed).count) 項會保留原位。新增項目排在當日末尾；來源沒有時間資料，時間衝突與順路仍需定位後確認。")
                        if days.count < maxDay { Text("旅程天數不足，請改用新旅程或調整模板天數。") }
                    }
                }
                Section {
                    Button(submitting ? "套用中…" : "確認套用") { Task { await confirm() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(submitting || !assigned || (selectedTripID != nil && days.count < maxDay))
                } footer: {
                    if !assigned { Text("請先回模板為每一天指定不重複的天數，並保留至少一個項目。") }
                }
            }
        }
        .navigationTitle("套用預覽")
        .task { await loadTrips() }
        .onChange(of: selectedTripID) { Task { await loadExisting() } }
    }

    private func loadTrips() async {
        do { trips = try await tripRepository.editableTrips(); await loadExisting() }
        catch { errorMessage = "讀取旅程失敗：\(error.localizedDescription)" }
    }

    private func loadExisting() async {
        guard let selectedTripID else { days = []; existingStops = []; return }
        do {
            days = try await tripRepository.days(of: selectedTripID)
            existingStops = try await tripRepository.stops(of: selectedTripID)
            errorMessage = nil
        } catch { errorMessage = "讀取行程失敗：\(error.localizedDescription)" }
    }

    private func confirm() async {
        guard assigned else { return }
        submitting = true
        defer { submitting = false }
        do {
            let expected = Dictionary(uniqueKeysWithValues: days.map { ($0.id.uuidString.lowercased(), $0.routeRevision) })
            let components = Calendar.current.dateComponents([.year, .month, .day], from: startDate)
            let date = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
            completedTripID = try await repository.applyTemplate(template, clientOperationID: operationID,
                tripID: selectedTripID, startDate: selectedTripID == nil ? date : nil,
                timeZone: selectedTripID == nil ? timeZoneID : nil, expectedDayRevisions: expected)
            errorMessage = nil
        } catch let error as BackendError where error == .staleRevision {
            errorMessage = "行程或模板已更新，請重新載入後再確認。"
            await loadExisting()
        } catch { errorMessage = "套用失敗：\(error.localizedDescription)" }
    }
}

/// 個人清單和旅伴共同清單分開；Viewer 也能查看自己的收藏與想買。
struct PersonalInboxItemsView: View {
    let session: SessionModel
    let kind: String
    @State private var items: [InboxItemRecord] = []
    @State private var errorMessage: String?

    private var repository: InboxRepository { InboxRepository(client: session.client) }

    var body: some View {
        List {
            if let errorMessage { ErrorText(errorMessage) }
            ForEach(items) { item in
                PersonalInboxRow(item: item, kind: kind, repository: repository) { updated in
                    if let index = items.firstIndex(where: { $0.id == updated.id }) { items[index] = updated }
                }
                .swipeActions {
                    Button("撤銷", role: .destructive) { Task { await undo(item) } }
                }
            }
        }
        .overlay {
            if items.isEmpty && errorMessage == nil {
                ContentUnavailableView(kind == "product" ? "還沒有個人想買" : "還沒有個人收藏",
                                       systemImage: kind == "product" ? "bag" : "bookmark")
            }
        }
        .navigationTitle(kind == "product" ? "只有我看得到 · 想買" : "只有我看得到 · 收藏")
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do { items = try await repository.listPersonalItems(kind: kind); errorMessage = nil }
        catch { errorMessage = "讀取失敗：\(error.localizedDescription)" }
    }

    private func undo(_ item: InboxItemRecord) async {
        do { _ = try await repository.updateItem(item, archived: false); items.removeAll { $0.id == item.id } }
        catch { errorMessage = "撤銷失敗：\(error.localizedDescription)" }
    }
}

private struct PersonalInboxRow: View {
    let item: InboxItemRecord
    let kind: String
    let repository: InboxRepository
    let onUpdated: (InboxItemRecord) -> Void
    @State private var resolves = false
    @State private var publishes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.displayName)
            Text("來源：\(item.sourceSpan)").font(.caption).foregroundStyle(.secondary)
            if kind == "place", item.resolutionStatus != "verified" {
                Button("確認地點") { resolves = true }.font(.caption)
            }
            Button("加入旅伴清單") { publishes = true }.font(.caption)
        }
        .sheet(isPresented: $resolves) {
            InboxPlaceResolveView(item: item, repository: repository) { updated in
                onUpdated(updated)
                resolves = false
            }
        }
        .sheet(isPresented: $publishes) {
            InboxPublishView(item: item, repository: repository) { publishes = false }
        }
    }
}
