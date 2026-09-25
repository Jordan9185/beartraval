import AppCore
import ShareCore
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
                                      timeZone: session.timeZone,
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
                Text(session.rawText).font(.subheadline).textSelection(.enabled)
                    .accessibilityIdentifier("rawText")
            }
            Section {
                Button("重試") { Task { phase = .parsing; await parse() } }
                    .accessibilityIdentifier("retryParse")
                Button("編輯原文") { editedText = session.rawText; phase = .editing }
                Button("略過匯入，建立空旅程") { Task { await commitEmpty() } }
            }
            if let errorMessage { ErrorText(errorMessage) }
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
            if let errorMessage { ErrorText(errorMessage) }
        }
    }

    private var failureText: String {
        if session.parseStatus == .parsing { return "解析花的時間比預期長，可能還在進行。請稍後按重試查看結果。" }
        return switch session.parseError {
        case "missing_api_key": "解析服務尚未設定（缺少 API key）。"
        case "rate_limited": "AI 解析次數已達上限（每小時 10 次），請稍後再試。"
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
        var latest: ImportSession
        do {
            latest = try await service.parse(importID: session.id)
        } catch {
            phase = .failed
            return
        }
        // 請求約 60 秒就逾時，但長行程要 1～3 分鐘：伺服器還在解析時繼續等結果，
        // 不當成失敗，也不重送（重送會再付一次 AI 費用；審查 H4）。
        let deadline = Date().addingTimeInterval(Self.maxParseWait)
        while latest.parseStatus == .parsing && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            if let next = try? await service.session(importID: session.id) { latest = next }
        }
        if latest.parseStatus == .parsed { apply(latest) } else {
            session = latest
            phase = .failed
        }
    }

    /// 超過就停止等待（伺服器端函式最長約 400 秒）。
    static let maxParseWait: TimeInterval = 450

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
            errorMessage = "儲存失敗：\(userMessage(for: error))"
        }
    }

    private func commitEmpty() async {
        do {
            onCreated(try await service.commit(importID: session.id, days: []))
        } catch {
            errorMessage = "建立失敗：\(userMessage(for: error))"
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
            errorMessage = "建立失敗：\(userMessage(for: error))"
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
    var timeZone: String? = nil
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
                if state.failedSearchCount > 0 && searchDone == searchTotal {
                    Label("\(state.failedSearchCount) 個地點的地圖搜尋暫時無法使用（可能離線）", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.orange)
                    Button("重新搜尋") { retryFailedSearches() }
                        .accessibilityIdentifier("retrySearch")
                }
                // 搜尋跑完才給批次操作，否則本來能自動定位的地點也會被標成未定位。
                if state.undecidedCount > 0 && searchDone == searchTotal {
                    Button("其餘 \(state.undecidedCount) 項先只保留名稱") { state.keepUndecidedAsText() }
                        .accessibilityIdentifier("keepUndecided")
                }
                if state.unconfirmedFixedCount > 0 {
                    Button("疑似固定的 \(state.unconfirmedFixedCount) 項都設為固定") { state.confirmSuspectedFixed() }
                }
            } footer: {
                Text("只有名稱明確相符才會自動選定。其他地點由你選，或只保留名稱（不計入路線，可用當地地圖查看）。")
            }
            if !warnings.isEmpty {
                Section {
                    DisclosureGroup("AI 備註（\(warnings.count)）") {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            Text(verbatim: warning).font(.subheadline)
                        }
                    }
                }
            }
            Section {
                DisclosureGroup("原文") {
                    Text(rawText).font(.subheadline).textSelection(.enabled).accessibilityIdentifier("rawText")
                }
            }
            // 只把需要使用者決定的項目攤開；App 代為處理的收在下面，可點開檢查或修改。
            ForEach(attention, id: \.self) { index in
                Section {
                    ConfirmItemView(item: $state.items[index], tripDates: state.tripDates, timeZone: timeZone) { await research(index, $0) }
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
                            ConfirmItemView(item: $state.items[index], tripDates: state.tripDates, timeZone: timeZone) { await research(index, $0) }
                        }
                    }
                    .accessibilityIdentifier("autoHandled")
                } footer: {
                    Text("名稱相符的地點已自動選定；Apple 地圖找不到的、航班等只保留名稱。點開可以修改。")
                }
            }
            Section {
                if !state.canSubmit {
                    Text("還有 \(state.remainingCount) 項需要確認").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("remainingCount")
                }
                if let errorMessage { ErrorText(errorMessage) }
            }
        }
        // 長表單的主要動作放在上方，不用捲到最底。
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isCommitting ? "建立中…" : "建立", action: onSubmit)
                    .disabled(!state.canSubmit || isCommitting)
                    .accessibilityIdentifier("submitImport")
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
        var cache: [String: PlaceLookup] = [:]
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
            // 城市定位不到時不加區域，也不把城市名塞進查詢（會把結果帶偏）。
            var result = PlaceLookup.notFound
            for text in [query, item.stop.placeName].compactMap({ $0 }).uniqued() {
                let key = "\(text)|\(area ?? "")"
                if let cached = cache[key] {
                    result = cached
                } else {
                    result = await placeSearch.lookup(text, around: center, limit: 5)
                    if Task.isCancelled { return }
                    // 失敗不快取，重新搜尋時才會真的再查。
                    if result != .unavailable { cache[key] = result }
                }
                if result != .notFound { break }
            }
            state.applySearch(result, at: index)
        }
    }

    /// 使用者換關鍵字搜尋：只更新候選，由使用者自己選（不自動選定）。
    private func research(_ index: Int, _ text: String) async {
        guard !text.isEmpty else { return }
        let area = state.items[index].stop.city ?? city
        let center: Coordinate? = if let area { await placeSearch.locate(city: area) } else { nil }
        var result = await placeSearch.lookup(text, around: center, limit: 5)
        if result == .notFound, center != nil { result = await placeSearch.lookup(text, around: nil, limit: 5) }
        state.items[index].candidates = result.options
        state.items[index].searchFailed = result == .unavailable
        state.items[index].searched = true
    }

    private func retryFailedSearches() {
        state.resetFailedSearches()
        Task { await searchAll() }
    }
}

struct ConfirmItemView: View {
    @Binding var item: ConfirmItem
    let tripDates: [String]
    var timeZone: String? = nil
    /// 用使用者輸入的關鍵字重新搜尋這一項。
    var research: ((String) async -> Void)? = nil
    @State private var showsSearch = false
    @State private var query = ""
    @State private var researching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let start = item.stop.startTime {
                    Text(start + (item.stop.timeIsApproximate ? "（推測）" : "")).monospacedDigit()
                }
                Text(item.label)
            }
            Text("「\(item.stop.sourceExcerpt)」").font(.caption).foregroundStyle(.secondary)
            if item.autoDecided, let note = autoNote {
                Label(note, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(item.stop.needsConfirmation, id: \.self) { reason in
                Label(reasonText(reason), systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }

        // 每一項都能改日期：AI 放錯天時可以直接調整。
        Picker("日期", selection: $item.date) {
            Text("未選").tag(String?.none)
            ForEach(Array(tripDates.enumerated()), id: \.element) { index, date in
                Text("第 \(index + 1) 天 · \(date)").tag(Optional(date))
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
        if item.searchFailed {
            Text("地圖搜尋暫時無法使用，請稍後重新搜尋。").font(.caption).foregroundStyle(.orange)
        } else if item.searched && item.candidates.isEmpty && item.needsSearch {
            Text("Apple 地圖沒收錄這個地點。").font(.caption).foregroundStyle(.secondary)
        }
        if item.searched && item.needsSearch && (item.candidates.isEmpty || item.decision == .pendingText) {
            LocalMapSearchButtons(name: item.label, countryCode: item.stop.countryCode
                                  ?? LocalMapCountry.guess(name: (item.stop.searchQuery ?? "") + item.label, timeZone: timeZone))
                .font(.callout)
        }
        if showsSearch, let research {
            HStack {
                TextField("換個名稱搜尋", text: $query)
                    .onSubmit { Task { await runSearch(research) } }
                Button(researching ? "搜尋中…" : "搜尋") { Task { await runSearch(research) } }
                    .buttonStyle(.borderless)
                    .disabled(researching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }

        HStack {
            Button {
                item.decision = .pendingText
            } label: {
                Label("只保留名稱", systemImage: item.decision == .pendingText ? "checkmark.circle.fill" : "text.bubble")
            }
            .accessibilityIdentifier("pending-\(item.id)")
            if item.needsSearch && research != nil && !showsSearch {
                Spacer()
                Button {
                    query = item.stop.placeName ?? item.label
                    showsSearch = true
                } label: {
                    Label("換關鍵字", systemImage: "magnifyingglass")
                }
            }
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

    private func runSearch(_ research: (String) async -> Void) async {
        researching = true
        defer { researching = false }
        await research(query.trimmingCharacters(in: .whitespaces))
    }

    private var autoNote: String? {
        switch item.decision {
        case .place(let option): "名稱相符，已自動選定：\(option.displayTitle)"
        case .pendingText: item.needsSearch ? "Apple 地圖沒收錄，已保留名稱，可用當地地圖查看" : "航班、交通等，保留名稱"
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
                Text("已經過 \(seconds / 60):\(String(format: "%02d", seconds % 60)) · 長行程約需 1～2 分鐘")
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
        var text = "第 \(max(progress.days, 1)) 天 · 已找到 \(progress.stops) 項"
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
