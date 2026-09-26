import AppCore
import ShareCore
import SwiftUI

/// Import → Parsing → Confirm Places → Create Trip（規格 §3.1、WP3）。
public struct ImportFlowView: View {
    let service: any ImportService
    let placeSearch: any PlaceSearching
    let discoveryRepository: InboxRepository?
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

    public init(session: ImportSession, service: any ImportService, placeSearch: any PlaceSearching,
                discoveryRepository: InboxRepository? = nil, onCreated: @escaping (Trip) -> Void) {
        self.service = service
        self.placeSearch = placeSearch
        self.discoveryRepository = discoveryRepository
        self.onCreated = onCreated
        _session = State(initialValue: session)
        _editedText = State(initialValue: session.rawText)
    }

    public var body: some View {
        Group {
            switch phase {
            case .parsing:
                ParsingProgressView(characters: session.rawText.count, progress: progress, started: parseStarted,
                                    suggestedTemplate: TripIdeaIntent.shouldSuggest(session.rawText, tripDays: session.tripDates.count))
            case .failed:
                failedView
            case .editing:
                editView
            case .confirming, .committing:
                if let confirm = Binding($confirm) {
                    ConfirmPlacesView(state: confirm, rawText: session.rawText, placeSearch: placeSearch,
                                      discoveryRepository: discoveryRepository,
                                      city: session.parseResult?.draft.cityCandidates.first,
                                      warnings: session.parseResult?.draft.warnings ?? [],
                                      suggestedTemplate: TripIdeaIntent.shouldSuggest(session.rawText, tripDays: session.tripDates.count),
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
    var discoveryRepository: InboxRepository? = nil
    let city: String?
    let warnings: [String]
    var suggestedTemplate = false
    var timeZone: String? = nil
    let isCommitting: Bool
    let errorMessage: String?
    let onSubmit: () -> Void
    @State private var webCandidates: [Int: [DiscoveredPlace]] = [:]
    @State private var webSearching: Set<Int> = []
    @State private var webMessages: [Int: String] = [:]

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
                    if suggestedTemplate && state.suggestedMatchCount > 0 {
                        Button("一次確認 \(state.suggestedMatchCount) 個名稱明確相符的地點") {
                            state.confirmSuggestedMatches()
                        }
                    }
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
                    confirmItem(at: index)
                } header: {
                    Text(state.items[index].date ?? "日期未定")
                }
            }
            if !handled.isEmpty {
                Section {
                    DisclosureGroup("已自動處理 \(handled.count) 項") {
                        ForEach(handled, id: \.self) { index in
                            confirmItem(at: index)
                        }
                    }
                    .accessibilityIdentifier("autoHandled")
                } footer: {
                    Text("名稱相符的地點已自動選定；航班等只保留名稱。點開可以修改。")
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
        let needs = attention.count
        return VStack(alignment: .leading, spacing: 2) {
            Text(suggestedTemplate ? "AI 建議 \(state.items.count) 項，可逐一調整" : "解析出 \(state.items.count) 項")
                .font(.subheadline.weight(.semibold))
            Text(searchDone < searchTotal ? "搜尋地點中，名稱相符的會自動選定"
                 : needs == 0 ? "全部已自動處理，可以直接建立"
                 : state.canSubmit ? "可以建立；\(needs) 項地點可再核對"
                 : "\(needs) 項需要你確認，其餘已自動處理")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("importSummary")
    }

    /// 需要使用者處理、且已經搜尋完（或不需搜尋）的項目。
    private var attention: [Int] {
        state.items.indices.filter { index in
            let item = state.items[index]
            let missingKoreanPlace = item.needsSearch && item.searched && !item.searchFailed && item.candidates.isEmpty
                && countryCode(for: item) == "KR"
            return (state.needsAttention.contains(index) || missingKoreanPlace) && (item.searched || !item.needsSearch)
        }
    }

    private var handled: [Int] {
        let needs = Set(attention)
        return state.items.indices.filter { !needs.contains($0) }
    }

    private var searchTotal: Int { state.items.filter(\.needsSearch).count }
    private var searchDone: Int { state.items.filter { $0.needsSearch && $0.searched }.count }

    private func countryCode(for item: ConfirmItem) -> String? {
        item.stop.countryCode ?? LocalMapCountry.guess(name: [item.stop.city, city, item.label]
            .compactMap { $0 }.joined(separator: " "), timeZone: timeZone)
    }

    private func confirmItem(at index: Int) -> some View {
        ConfirmItemView(item: $state.items[index], tripDates: state.tripDates, timeZone: timeZone,
                        webCandidates: webCandidates[index] ?? [], webSearching: webSearching.contains(index),
                        webMessage: webMessages[index], discoverWeb: discoveryRepository == nil ? nil : {
                            Task { await discoverWeb(at: index) }
                        }, useWebCandidate: { candidate in
                            Task { await research(index, candidate.searchQuery) }
                        }) { await research(index, $0) }
    }

    private func discoverWeb(at index: Int) async {
        guard let discoveryRepository, state.items.indices.contains(index), !webSearching.contains(index) else { return }
        let item = state.items[index]
        webSearching.insert(index)
        webMessages[index] = nil
        defer { webSearching.remove(index) }
        do {
            let context = [item.stop.city ?? city, item.stop.sourceExcerpt, item.stop.searchQuery]
                .compactMap { $0 }.joined(separator: "\n")
            let candidates = try await discoveryRepository.discoverPlaces(query: item.label, context: context)
            webCandidates[index] = candidates
            if candidates.isEmpty { webMessages[index] = "目前找不到可核對來源的店家，這項仍只保留名稱。" }
        } catch let error as PlaceDiscoveryError {
            webMessages[index] = error.userMessage
        } catch {
            webMessages[index] = "店家查找失敗：\(userMessage(for: error))"
        }
    }

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
    var webCandidates: [DiscoveredPlace] = []
    var webSearching = false
    var webMessage: String? = nil
    var discoverWeb: (() -> Void)? = nil
    var useWebCandidate: ((DiscoveredPlace) -> Void)? = nil
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
            // 已自動處理的項目只留結論，原文片段留給需要判斷的項目（樣式指南）。
            if item.stop.sourceExcerpt.hasPrefix("AI 建議：") {
                Text(item.stop.sourceExcerpt.components(separatedBy: "；來源：").first ?? item.stop.sourceExcerpt)
                    .font(.caption).foregroundStyle(.secondary)
                if let source = item.stop.sourceExcerpt.components(separatedBy: "；來源：").last,
                   let url = URL(string: source), url.scheme == "https" {
                    Link("查看建議來源", destination: url).font(.caption)
                }
            } else if !item.autoDecided {
                Text("「\(item.stop.sourceExcerpt)」").font(.caption).foregroundStyle(.secondary)
            }
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
                PlaceOptionRow(title: option.displayTitle, address: option.address, selected: item.decision == .place(option))
            }
            .accessibilityIdentifier("candidate-\(item.id)-\(option.name)")
        }
        if item.searchFailed {
            Text("地圖搜尋暫時無法使用，請稍後重新搜尋。").font(.caption).foregroundStyle(.orange)
        } else if item.searched && item.candidates.isEmpty && item.needsSearch {
            Text("Apple 地圖沒收錄這個地點。").font(.caption).foregroundStyle(.secondary)
        }
        if item.searched && item.candidates.isEmpty && item.needsSearch,
           (item.stop.countryCode ?? LocalMapCountry.guess(name: item.label, timeZone: timeZone)) == "KR",
           let discoverWeb {
            Button("AI 查韓文店名與地址", systemImage: "sparkles", action: discoverWeb)
                .disabled(webSearching)
            if webSearching { ProgressView("正在查有來源的候選店家…") }
            if let webMessage { Text(webMessage).font(.caption).foregroundStyle(.secondary) }
        }
        ForEach(webCandidates) { candidate in
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.koreanName ?? candidate.name).font(.subheadline.weight(.semibold))
                if let address = candidate.addressLocal { Text(address).font(.caption).textSelection(.enabled) }
                Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                if let url = URL(string: candidate.sourceURL), url.scheme == "https" {
                    Link("查看來源", destination: url).font(.caption)
                }
                if let useWebCandidate {
                    Button("用此店名搜尋定位") { useWebCandidate(candidate) }
                }
                LocalMapSearchButtons(name: candidate.searchQuery, countryCode: "KR")
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
        if item.searched && item.needsSearch && (item.candidates.isEmpty || item.decision == .pendingText) {
            LocalMapSearchButtons(name: item.label, countryCode: item.stop.countryCode
                                  ?? LocalMapCountry.guess(name: (item.stop.searchQuery ?? "") + item.label, timeZone: timeZone))
                .font(.callout)
        }
        if showsSearch, let research {
            PlaceSearchField(text: $query, placeholder: "換個名稱搜尋", isSearching: researching) { Task { await runSearch(research) } }
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
    var suggestedTemplate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            step(done: true, active: false, title: "已送出需求（\(characters.formatted()) 字）")
            step(done: writing, active: !writing, title: suggestedTemplate ? "AI 搜尋公開旅遊資料" : "AI 閱讀行程",
                 detail: writing ? nil : suggestedTemplate ? "查具名景點，保留可回查的來源" : "分辨地點與備註")
            step(done: false, active: writing, title: suggestedTemplate ? "安排建議樣板" : "整理成每日行程", detail: draftDetail)
            step(done: false, active: false, title: "搜尋地點，讓你逐一確認")
            TimelineView(.periodic(from: started, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                Text("已經過 \(seconds / 60) 分 \(seconds % 60) 秒 · 長行程約需 1～2 分鐘")
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
