import AppCore
import SwiftUI

/// Import → Parsing → Confirm Places → Create Trip（規格 §3.1、WP3）。
public struct ImportFlowView: View {
    let service: any ImportService
    let placeSearch: any PlaceSearching
    let onCreated: (Trip) -> Void

    @State private var session: ImportSession
    @State private var phase: Phase = .parsing
    @State private var editedText: String
    @State private var confirm: ConfirmPlacesState?
    @State private var errorMessage: String?
    @State private var progress: ParseProgress?
    @State private var parseStarted = Date()

    enum Phase: Equatable {
        case parsing
        case failed
        case editing
        case confirming
        case committing
    }

    public init(session: ImportSession, service: any ImportService, placeSearch: any PlaceSearching, onCreated: @escaping (Trip) -> Void) {
        self.service = service
        self.placeSearch = placeSearch
        self.onCreated = onCreated
        _session = State(initialValue: session)
        _editedText = State(initialValue: session.rawText)
    }

    public var body: some View {
        Group {
            switch phase {
            case .parsing:
                ParsingProgressView(characters: session.rawText.count, progress: progress, started: parseStarted)
            case .failed:
                failedView
            case .editing:
                editView
            case .confirming, .committing:
                if let confirm = Binding($confirm) {
                    ConfirmPlacesView(state: confirm, rawText: session.rawText, placeSearch: placeSearch,
                                      city: session.parseResult?.draft.cityCandidates.first,
                                      warnings: session.parseResult?.draft.warnings ?? [],
                                      isCommitting: phase == .committing, errorMessage: errorMessage) {
                        Task { await commit() }
                    }
                }
            }
        }
        .navigationTitle(session.tripName)
        .task {
            if session.parseStatus == .parsed { apply(session) } else if phase == .parsing { await parse() }
        }
    }

    private var failedView: some View {
        Form {
            Section {
                Label("解析失敗", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(failureText).foregroundStyle(.secondary)
            }
            Section("原文（已保留）") {
                Text(session.rawText).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("rawText")
            }
            Section {
                Button("重試") { Task { phase = .parsing; await parse() } }
                    .accessibilityIdentifier("retryParse")
                Button("編輯原文") { editedText = session.rawText; phase = .editing }
                Button("略過匯入，建立空旅程") { Task { await commitEmpty() } }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
    }

    private var editView: some View {
        Form {
            Section("原文") {
                TextEditor(text: $editedText).frame(minHeight: 240)
                    .accessibilityIdentifier("rawTextEditor")
            }
            Section {
                Button("儲存並重新解析") { Task { await saveAndParse() } }
                    .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消") { phase = .failed }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
    }

    private var failureText: String {
        switch session.parseError {
        case "missing_api_key": "解析服務尚未設定（缺少 API key）。"
        case "refusal": "無法處理這段文字。"
        case "max_tokens": "文字太長，請分段匯入。"
        case "invalid_output": "解析結果格式不正確。"
        default: "暫時無法連線到解析服務。"
        }
    }

    private func parse() async {
        progress = nil
        parseStarted = Date()
        // 解析是一個長請求；同時輪詢服務端寫入的進度。
        let poll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                if let latest = try? await service.session(importID: session.id), latest.parseStatus == .parsing {
                    progress = latest.parseProgress
                }
            }
        }
        defer { poll.cancel() }
        do {
            let updated = try await service.parse(importID: session.id)
            if updated.parseStatus == .parsed { apply(updated) } else {
                session = updated
                phase = .failed
            }
        } catch {
            phase = .failed
        }
    }

    private func apply(_ updated: ImportSession) {
        session = updated
        guard let draft = updated.parseResult?.draft else {
            phase = .failed
            return
        }
        confirm = ConfirmPlacesState(session: updated, draft: draft)
        phase = .confirming
    }

    private func saveAndParse() async {
        do {
            session = try await service.updateText(importID: session.id, rawText: editedText)
            errorMessage = nil
            phase = .parsing
            await parse()
        } catch {
            errorMessage = "儲存失敗：\(error.localizedDescription)"
        }
    }

    private func commitEmpty() async {
        do {
            onCreated(try await service.commit(importID: session.id, days: []))
        } catch {
            errorMessage = "建立失敗：\(error.localizedDescription)"
        }
    }

    private func commit() async {
        guard let state = confirm, state.canSubmit else { return }
        phase = .committing
        do {
            var ids: [String: UUID] = [:]
            for place in state.placesToRegister {
                ids[place.providerPlaceId] = try await service.registerPlace(place).id
            }
            onCreated(try await service.commit(importID: session.id, days: state.commitDays(placeIDs: ids)))
        } catch {
            errorMessage = "建立失敗：\(error.localizedDescription)"
            phase = .confirming
        }
    }
}

struct ConfirmPlacesView: View {
    @Binding var state: ConfirmPlacesState
    let rawText: String
    let placeSearch: any PlaceSearching
    let city: String?
    let warnings: [String]
    let isCommitting: Bool
    let errorMessage: String?
    let onSubmit: () -> Void

    var body: some View {
        Form {
            Section {
                summary
                if searchTotal > 0 && searchDone < searchTotal {
                    ProgressView(value: Double(searchDone), total: Double(searchTotal)) {
                        Text("搜尋地點 \(searchDone)/\(searchTotal)").font(.caption)
                    }
                }
                if state.undecidedCount > 0 {
                    Button("其餘 \(state.undecidedCount) 項先保留為文字，之後再確認") { state.keepUndecidedAsText() }
                        .accessibilityIdentifier("keepUndecided")
                }
                if state.unconfirmedFixedCount > 0 {
                    Button("疑似固定的 \(state.unconfirmedFixedCount) 項都設為固定") { state.confirmSuspectedFixed() }
                }
            } footer: {
                Text("只有名稱明確相符才會自動選定。其他地點由你選，或先保留為文字（不參與路線），之後在行程裡再確認。")
            }
            if !warnings.isEmpty {
                Section {
                    DisclosureGroup("AI 備註（\(warnings.count)）") {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            Text(verbatim: warning).font(.callout)
                        }
                    }
                }
            }
            Section {
                DisclosureGroup("原文") {
                    Text(rawText).font(.callout).textSelection(.enabled).accessibilityIdentifier("rawText")
                }
            }
            // 只把需要使用者決定的項目攤開；App 代為處理的收在下面，可點開檢查或修改。
            ForEach(attention, id: \.self) { index in
                Section {
                    ConfirmItemView(item: $state.items[index], tripDates: state.tripDates)
                } header: {
                    Text(state.items[index].date ?? "日期未定")
                }
            }
            if searchDone < searchTotal {
                Section {
                    Label("還有 \(searchTotal - searchDone) 個地點搜尋中…", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
            }
            if !handled.isEmpty {
                Section {
                    DisclosureGroup("已自動處理 \(handled.count) 項") {
                        ForEach(handled, id: \.self) { index in
                            ConfirmItemView(item: $state.items[index], tripDates: state.tripDates)
                        }
                    }
                    .accessibilityIdentifier("autoHandled")
                } footer: {
                    Text("名稱相符的地點已自動選定；Apple 地圖找不到的、航班等先保留為文字。點開可以修改。")
                }
            }
            Section {
                Button(isCommitting ? "建立中…" : "建立旅程", action: onSubmit)
                    .disabled(!state.canSubmit || isCommitting)
                    .accessibilityIdentifier("submitImport")
                if !state.canSubmit {
                    Text("還有 \(state.remainingCount) 項需要確認").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("remainingCount")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .task { await searchAll() }
    }

    private var summary: some View {
        let needs = state.needsAttention.count
        return VStack(alignment: .leading, spacing: 2) {
            Text("解析出 \(state.items.count) 項").font(.subheadline.weight(.semibold))
            Text(searchDone < searchTotal ? "搜尋地點中，名稱相符的會自動選定"
                 : needs == 0 ? "全部已自動處理，可以直接建立" : "\(needs) 項需要你確認，其餘已自動處理")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("importSummary")
    }

    /// 需要使用者處理、且已經搜尋完（或不需搜尋）的項目。
    private var attention: [Int] {
        state.needsAttention.filter { state.items[$0].searched || !state.items[$0].needsSearch }
    }

    private var handled: [Int] {
        let needs = Set(state.needsAttention)
        return state.items.indices.filter { !needs.contains($0) }
    }

    private var searchTotal: Int { state.items.filter(\.needsSearch).count }
    private var searchDone: Int { state.items.filter { $0.needsSearch && $0.searched }.count }

    /// 依序查詢（MapKit 有節流）；只列候選，不自動選定。
    /// 每個地點在自己的城市一帶搜尋，跨國旅程才不會拿首爾去搜廣島的地點。
    private func searchAll() async {
        var centers: [String: Coordinate?] = [:]
        var cache: [String: [PlaceOption]] = [:]
        for index in state.items.indices where !state.items[index].searched {
            let item = state.items[index]
            guard item.needsSearch, let query = item.stop.searchQuery ?? item.stop.placeName else {
                state.items[index].searched = true
                continue
            }
            let area = item.stop.city ?? city
            var center: Coordinate?
            if let area {
                if let known = centers[area] {
                    center = known
                } else {
                    center = await placeSearch.locate(city: area)
                    centers[area] = center
                }
            }
            // 先用當地語言的查詢；找不到再用原文名稱（例如「LAVITA Hotel」比「라비타 호텔 청담」好找）。
            var results: [PlaceOption] = []
            for text in [query, item.stop.placeName].compactMap({ $0 }).uniqued() {
                let key = "\(text)|\(area ?? "")"
                if let cached = cache[key] {
                    results = cached
                } else {
                    // 城市定位不到時不加區域，也不把城市名塞進查詢（會把結果帶偏）。
                    results = center != nil ? await placeSearch.search(text, around: center, limit: 5)
                                            : await placeSearch.search(text, near: nil, limit: 5)
                    if Task.isCancelled { return }
                    cache[key] = results
                }
                if !results.isEmpty { break }
            }
            state.applySearchResults(results, at: index)
        }
    }
}

struct ConfirmItemView: View {
    @Binding var item: ConfirmItem
    let tripDates: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let start = item.stop.startTime {
                    Text(start + (item.stop.timeIsApproximate ? "（推測）" : "")).monospacedDigit()
                }
                Text(item.label).font(.headline)
            }
            Text("「\(item.stop.sourceExcerpt)」").font(.caption).foregroundStyle(.secondary)
            if item.autoDecided, let note = autoNote {
                Label(note, systemImage: "wand.and.stars").font(.caption).foregroundStyle(.tint)
            }
            ForEach(item.stop.needsConfirmation, id: \.self) { reason in
                Label(reasonText(reason), systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }

        if item.date == nil || item.stop.needsConfirmation.contains(.ambiguousDate) {
            Picker("日期", selection: $item.date) {
                Text("未選").tag(String?.none)
                ForEach(tripDates, id: \.self) { Text($0).tag(Optional($0)) }
            }
        }

        if item.stop.fixedSuspected {
            Picker("固定行程？\(item.stop.fixedReason.map { "（\($0)）" } ?? "")", selection: $item.fixed) {
                Text("未確認").tag(Bool?.none)
                Text("固定").tag(Optional(true))
                Text("不固定").tag(Optional(false))
            }
            .accessibilityIdentifier("fixed-\(item.id)")
        }

        if !item.searched && item.needsSearch {
            ProgressView("搜尋候選地點…")
        }
        ForEach(item.candidates) { option in
            Button {
                item.decision = .place(option)
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(option.displayTitle)
                        if let address = option.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if item.decision == .place(option) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
            }
            .accessibilityIdentifier("candidate-\(item.id)-\(option.name)")
        }
        if item.searched && item.candidates.isEmpty && item.needsSearch {
            Text("Apple 地圖找不到這個地點，可以先保留為文字，之後在行程裡再確認。").font(.caption).foregroundStyle(.secondary)
        }

        HStack {
            Button {
                item.decision = .pendingText
            } label: {
                Label("保留為待確認文字", systemImage: item.decision == .pendingText ? "checkmark.circle.fill" : "text.bubble")
            }
            .accessibilityIdentifier("pending-\(item.id)")
            Spacer()
            Button(role: .destructive) {
                item.decision = .remove
            } label: {
                Label("移除", systemImage: item.decision == .remove ? "checkmark.circle.fill" : "trash")
            }
            .accessibilityIdentifier("remove-\(item.id)")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private var autoNote: String? {
        switch item.decision {
        case .place(let option): "名稱相符，已自動選定：\(option.displayTitle)"
        case .pendingText: item.needsSearch ? "Apple 地圖找不到，已保留為文字" : "不是地點（航班、交通等），保留為文字"
        default: nil
        }
    }

    private func reasonText(_ reason: ParsedStop.Reason) -> String {
        switch reason {
        case .ambiguousBranch: "分店不明，請選擇"
        case .unknownPlace: "可能不是可搜尋的地點"
        case .ambiguousDate: "日期不明確"
        case .ambiguousTime: "時間不明確"
        }
    }
}

/// 解析中的畫面：顯示實際進度（服務端邊串流邊回報），不是假的轉圈。
struct ParsingProgressView: View {
    let characters: Int
    let progress: ParseProgress?
    let started: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            step(done: true, active: false, title: "已送出原文（\(characters.formatted()) 字）")
            step(done: writing, active: !writing, title: "AI 閱讀行程",
                 detail: writing ? nil : "先讀完整份行程，分辨哪些是地點、哪些只是備註")
            step(done: false, active: writing, title: "整理成每日行程", detail: draftDetail)
            step(done: false, active: false, title: "搜尋地點，讓你逐一確認")
            TimelineView(.periodic(from: started, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                Text("已經過 \(seconds / 60):\(String(format: "%02d", seconds % 60))・長行程約需 1～2 分鐘")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("parsingProgress")
    }

    private var writing: Bool { progress?.stage == "writing" }

    private var draftDetail: String? {
        guard let progress, writing else { return nil }
        var text = "第 \(max(progress.days, 1)) 天・已找到 \(progress.stops) 項"
        if let last = progress.lastPlace { text += "（最新：\(last)）" }
        return text
    }

    private func step(done: Bool, active: Bool, title: String, detail: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if active {
                    ProgressView()
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(done || active ? .primary : .secondary)
                if let detail { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
