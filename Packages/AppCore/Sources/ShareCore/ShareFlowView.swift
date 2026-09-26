import AppCore
import SwiftUI

/// 分享最小閉環（規格 §5.3、WP6）：分享卡 → 辨識結果／待確認 → 選 Trip → Route Match →
/// 加入某天／先收藏／取消。資料不足時列出缺少的資訊並允許手動補填（AC-04）。
/// Extension 與 App（處理草稿時）共用。
public struct ShareFlowView: View {
    public enum Outcome: Equatable, Sendable {
        case added
        case saved(duplicate: Bool)
        case draftSaved
    }

    let repository: TripRepository?
    let matcher: RouteMatcher
    let placeSearch: any PlaceSearching
    let saveDraft: (() throws -> Void)?
    let discoveryRepository: InboxRepository?
    let onFinish: (Outcome) -> Void

    @State private var analysis: ShareAnalysis
    /// 分享進來的截圖（有的話在裝置上辨識文字，找出店名與地址）。
    @State private var screenshot: Data?
    @State private var screenshotLines: [String] = []
    @State private var recognizedLines: [String] = []
    /// 截圖裡的地址（可修改）；原文地址會存成地點的當地文字地址，給計程車卡片用。
    @State private var screenshotAddress = ""
    /// 截圖內容看起來是哪個國家（可修改）。
    @State private var country: String?
    @State private var readingScreenshot = false
    /// 截圖的 OCR 與 AI 查找尚未結束時，不顯示可能錯誤的暫存店名及後續操作。
    @State private var awaitingScreenshotResult = false
    @State private var discovered: [DiscoveredPlace] = []
    @State private var discovering = false
    @State private var discoveryMessage: String?
    @State private var query: String
    @State private var category: SavedCategory = .place
    /// 使用者自己選過類別後，不再用截圖文字或店家類型覆蓋。
    @State private var categoryChosen = false
    @State private var candidates: [PlaceOption] = []
    @State private var searched = false
    @State private var selected: PlaceOption?
    @State private var signedIn: Bool?
    @State private var trips: [Trip] = []
    @State private var tripID: UUID?
    @State private var matches: [DayMatch] = []
    @State private var dayTitles: [UUID: String] = [:]
    @State private var computing = false
    @State private var pending: AddToDayFlow.Pending?
    @State private var point: RoutePoint?
    @State private var notice: String?
    @State private var errorMessage: String?
    @State private var busy = false

    public init(content: ShareContent, repository: TripRepository?, matcher: RouteMatcher, placeSearch: any PlaceSearching,
                saveDraft: (() throws -> Void)?, discoveryRepository: InboxRepository? = nil,
                onFinish: @escaping (Outcome) -> Void) {
        self.repository = repository
        self.matcher = matcher
        self.placeSearch = placeSearch
        self.saveDraft = saveDraft
        self.discoveryRepository = discoveryRepository
        self.onFinish = onFinish
        let analysis = ShareAnalysis(content)
        _analysis = State(initialValue: analysis)
        _query = State(initialValue: analysis.suggestedQuery ?? "")
        _screenshot = State(initialValue: content.imageJPEG)
        // 一開始就標成辨識中，登入檢查那段時間不會先閃出「沒有店名」的提醒。
        _readingScreenshot = State(initialValue: Self.wantsScreenshotText(content.imageJPEG, analysis, query: analysis.suggestedQuery ?? ""))
        _awaitingScreenshotResult = State(initialValue: Self.wantsScreenshotText(content.imageJPEG, analysis, query: analysis.suggestedQuery ?? ""))
    }

    /// 有截圖、文字又看不出店名時，才需要辨識截圖文字。
    private static func wantsScreenshotText(_ screenshot: Data?, _ analysis: ShareAnalysis, query: String) -> Bool {
        screenshot != nil && analysis.mapHint == nil && (query.isEmpty || !analysis.missing.isEmpty)
    }

    public var body: some View {
        Form {
            sourceSection
            if signedIn == false {
                Section {
                    Label("尚未登入或無法連線。", systemImage: "person.crop.circle.badge.exclamationmark")
                    if let saveDraft {
                        Button("存成草稿，開啟 App 後繼續") {
                            do { try saveDraft(); onFinish(.draftSaved) } catch { errorMessage = "無法儲存草稿。" }
                        }
                    }
                }
            } else if awaitingScreenshotResult {
                if !readingScreenshot {
                    Section { ProgressView("AI 正在查店名與地址…") }
                }
            } else {
                discoverySection
                placeSection
                screenshotSuggestions
                tripSection
                if selected != nil, tripID != nil { routeSection }
                actionSection
            }
            if let errorMessage { ErrorText(errorMessage) }
        }
        .task { await start() }
    }

    // MARK: 來源與缺少的資訊

    private var sourceSection: some View {
        Section("分享內容") {
            if let url = analysis.sourceURL {
                Text(url.host.map { platformName == "網頁" ? $0 : "\(platformName) · \($0)" } ?? url.absoluteString)
            } else if screenshot != nil {
                LabeledContent("來源", value: "截圖")
            } else {
                LabeledContent("來源", value: "文字")
            }
            if let screenshot, let image = platformImage(screenshot) {
                image.resizable().scaledToFit().frame(maxHeight: 180).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if readingScreenshot { ProgressView("讀取截圖中的文字…") }
            if let excerpt = analysis.excerpt {
                Text(excerpt).font(.subheadline).lineLimit(4)
            }
            // 截圖讀得到文字時，「拿不到貼文內容／沒有店名」的提醒就不適用。
            if screenshotLines.isEmpty && !readingScreenshot && !awaitingScreenshotResult {
                ForEach(Array(analysis.missing.enumerated()), id: \.offset) { _, missing in
                    Label(missingText(missing), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func platformImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }

    /// 截圖裡讀到、可能是店名或地址的文字；點一下就用它搜尋。
    @ViewBuilder
    private var screenshotSuggestions: some View {
        if !screenshotLines.isEmpty {
            Section {
                ForEach(screenshotLines, id: \.self) { line in
                    Button {
                        if ScreenshotText.isAddress(line) {
                            screenshotAddress = line
                        } else {
                            query = line
                            Task { await search() }
                        }
                    } label: {
                        Label(line, systemImage: ScreenshotText.isAddress(line) ? "mappin" : "text.quote")
                    }
                }
            } header: {
                Text("截圖中的文字")
            } footer: {
                Text("在手機上辨識，不會上傳。點店名會用它搜尋、點地址會填進地址欄；地點仍由你從候選中選定。")
            }
        }
    }

    private var platformName: String {
        switch analysis.platform {
        case .threads: "Threads"
        case .instagram: "Instagram"
        case .googleMaps: "Google 地圖"
        case .appleMaps: "Apple 地圖"
        case .naverMap: "Naver 地圖"
        case .kakaoMap: "Kakao 地圖"
        case .web, .none: "網頁"
        }
    }

    private func missingText(_ missing: ShareAnalysis.Missing) -> String {
        switch missing {
        case .noPostContent: "拿不到貼文內容（只收到連結），請手動輸入店名。"
        case .noPlaceName: "沒有可搜尋的店名或座標，請手動輸入。"
        case .shortLinkUnresolved: "短網址無法展開，請手動輸入店名。"
        }
    }

    // MARK: 地點

    static let countries: [(code: String, name: String)] = [("KR", "韓國"), ("JP", "日本"), ("TW", "台灣"), ("HK", "香港")]

    @ViewBuilder
    private var discoverySection: some View {
        if screenshot != nil {
            if discovering { ProgressView("AI 正在查韓文店名與地址…") }
            if let discoveryMessage { Text(discoveryMessage).font(.caption).foregroundStyle(.secondary) }
            if !discovered.isEmpty {
                Section {
                    ForEach(discovered) { suggestion in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(suggestion.koreanName ?? suggestion.name).font(.headline)
                            if let address = suggestion.addressLocal {
                                Text("韓文地址線索：\(address)").textSelection(.enabled)
                            }
                            Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                            LocalMapSearchButtons(name: suggestion.searchQuery, countryCode: "KR")
                            if let url = URL(string: suggestion.sourceURL), url.scheme == "https" {
                                Link("查看網路來源", destination: url).font(.caption)
                            }
                            Button("帶入這間店的店名與地址") {
                                query = suggestion.koreanName ?? suggestion.name
                                if let address = suggestion.addressLocal { screenshotAddress = address }
                                country = "KR"
                                Task { await search() }
                            }
                        }
                    }
                    Button("重新查韓文店名與地址") { Task { await discoverScreenshot() } }
                } header: {
                    Text("AI 找到的韓國店家候選")
                } footer: {
                    Text("地址只顯示網頁來源明示的原文；請在 Naver／Kakao 核對分店。行程定位仍須選定地圖點。")
                }
            }
            if !discovering && discovered.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("用目前文字查韓文店名與地址") { Task { await discoverScreenshot() } }
            }
        }
    }

    @ViewBuilder
    private var placeSection: some View {
        Section {
            if screenshot != nil {
                // 截圖辨識出來的店名、地址都可以改。
                LabeledContent("店名") { PlaceSearchField(text: $query) { Task { await search() } } }
                LabeledContent("地址") {
                    TextField("截圖中的地址（選填）", text: $screenshotAddress, axis: .vertical)
                        .autocorrectionDisabled()
                }
                Picker("國家／地區", selection: $country) {
                    Text("看不出來").tag(String?.none)
                    ForEach(Self.countries, id: \.code) { Text($0.name).tag(Optional($0.code)) }
                }
                if country == "KR" && discovered.isEmpty && !query.isEmpty {
                    LocalMapSearchButtons(name: query, countryCode: "KR")
                }
            } else {
                PlaceSearchField(text: $query) { Task { await search() } }
            }
            Picker("類別", selection: Binding(get: { category }, set: { category = $0; categoryChosen = true })) {
                ForEach(SavedCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text("地點")
        } footer: {
            if screenshot != nil { Text("辨識有錯可以直接改；店名改完按「搜尋」重找。") }
        }
        Section {
            ForEach(candidates) { option in
                // 再點一次同一個候選就取消選取（誤觸時用）。
                Button { toggle(option) } label: {
                    PlaceOptionRow(title: option.displayTitle, address: option.address, selected: selected == option)
                }
            }
            if searched && candidates.isEmpty {
                Text("地圖暫時找不到可確認的定位點；上方仍可查看韓文店名、地址和在地地圖。")
                    .font(.caption).foregroundStyle(.secondary)
                if !query.isEmpty {
                    LocalMapSearchButtons(name: query, countryCode: country ?? LocalMapCountry.guess(name: query + screenshotAddress, timeZone: nil))
                }
            }
            if let selected {
                Button("取消選取「\(selected.displayTitle)」", role: .cancel) { toggle(selected) }
            }
        } header: {
            if searched { Text("供行程定位的地圖候選") }
        } footer: {
            if selected == nil && !candidates.isEmpty { Text("請選擇正確的店家或分店；再點一次可以取消。") }
        }
    }

    private func toggle(_ option: PlaceOption) {
        if selected == option {
            selected = nil
            matches = []
            withdrawPending()
        } else {
            selected = option
            if !categoryChosen, let kind = option.category { category = kind }
            Task { await computeMatches() }
        }
    }

    /// 還沒確認的加入要求撤回，不留在伺服器上。
    private func withdrawPending() {
        if let id = pending?.proposal.id, let repository { Task { try? await repository.reject(proposalID: id) } }
        pending = nil
    }

    /// 選定的地點，加上使用者確認過的原文店名與地址（截圖辨識、可修改）。
    private func confirmedDraft(_ option: PlaceOption) -> PlaceDraft {
        var draft = option.draft
        let country = draft.countryCode ?? country
        let name = query.trimmingCharacters(in: .whitespaces)
        if draft.nameLocal == nil, !name.isEmpty,
           (country == "KR" && PlaceNaming.hasHangul(name)) || (country == "JP" && PlaceNaming.hasKana(name)) {
            draft.nameLocal = name
        }
        if draft.nameZh == nil, PlaceNaming.looksChinese(name) { draft.nameZh = name }
        let address = screenshotAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty, LocalAddress.locale(for: country) != nil, LocalAddress.isLocal(address, countryCode: country) {
            draft.addressLocal = address
        }
        return draft
    }

    // MARK: Trip 與順路

    private var tripSection: some View {
        Section("加入哪個旅程") {
            if trips.isEmpty {
                Text(signedIn == nil ? "載入中…" : "沒有可以新增的旅程。請先在 App 建立旅程，或請擁有者給你編輯權限。").foregroundStyle(.secondary)
            } else {
                Picker("旅程", selection: $tripID) {
                    ForEach(trips) { Text($0.name).tag(Optional($0.id)) }
                }
                .onChange(of: tripID) { Task { await computeMatches() } }
            }
        }
    }

    private var routeSection: some View {
        Section("順路") {
            if computing { ProgressView("計算中…") }
            if let pending {
                Text("\(dayTitles[pending.proposal.dayId] ?? "")，\(pending.positionText)")
                MatchNumbers(insertion: pending.insertion) { $0.flatMap { pending.stopLabels[$0] } }
                if let notice { Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Button(busy ? "加入中…" : "確認加入") { Task { await confirm() } }.disabled(busy)
                Button("不加入") { withdrawPending() }
            } else if let best = RouteMatcher.bestDay(matches), let insertion = best.best {
                Text("最適合：\(dayTitles[best.dayID] ?? "")")
                MatchNumbers(insertion: insertion) { _ in nil }
            } else if !computing && !matches.isEmpty {
                Text("所有日子都無法估算路線，可以先收藏。").foregroundStyle(.secondary)
            }
            if pending == nil {
                ForEach(matches.filter { $0.best != nil }, id: \.dayID) { match in
                    Button("加入 \(dayTitles[match.dayID] ?? "")（+\(match.best?.addedTravelMinutes ?? 0) 分）…") {
                        Task { await propose(match) }
                    }
                    .disabled(busy)
                }
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button(busy ? "處理中…" : "先收藏") { Task { await save() } }
                .disabled(busy || tripID == nil || (selected == nil && query.trimmingCharacters(in: .whitespaces).isEmpty))
        } footer: {
            Text(selected == nil ? "未選地點時只收藏名稱，之後可補定位；未定位前不計入路線。" : "收藏到共同的收藏清單，不會改動正式行程。")
        }
    }

    // MARK: 動作

    private func start() async {
        if analysis.missing.contains(.shortLinkUnresolved), let url = analysis.sourceURL, let expanded = await MapLink.expand(url) {
            var content = ShareContent(urls: [expanded])
            content.texts = analysis.excerpt.map { [$0] } ?? []
            let expandedAnalysis = ShareAnalysis(content)
            analysis.mapHint = expandedAnalysis.mapHint
            analysis.missing = expandedAnalysis.missing
            if query.isEmpty { query = expandedAnalysis.suggestedQuery ?? "" }
        }
        guard let repository, await repository.isSignedIn() else {
            readingScreenshot = false
            awaitingScreenshotResult = false
            signedIn = false
            return
        }
        do {
            trips = try await repository.editableTrips()
            signedIn = true
            tripID = Self.defaultTrip(trips)?.id
        } catch {
            readingScreenshot = false
            awaitingScreenshotResult = false
            signedIn = false
            return
        }
        // 有截圖、文字又看不出店名時，在裝置上辨識截圖文字。
        if let screenshot, Self.wantsScreenshotText(screenshot, analysis, query: query) {
            readingScreenshot = true
            let lines = await ScreenshotText.recognize(jpeg: screenshot)
            recognizedLines = lines
            let guess = ScreenshotText.guess(from: lines)
            if !categoryChosen, let kind = guess.category { category = kind }
            screenshotAddress = guess.address ?? ""
            country = guess.country
            screenshotLines = ([guess.name, guess.address].compactMap { $0 } + guess.otherLines)
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if let best = guess.name ?? guess.address { query = best }
            readingScreenshot = false
            if (country == "KR" || country == nil), discoveryRepository != nil {
                await discoverScreenshot()
                return
            }
        } else {
            readingScreenshot = false
        }
        awaitingScreenshotResult = false
        if let coordinate = analysis.mapHint?.coordinate, query.isEmpty {
            candidates = await placeSearch.nearby(coordinate, limit: 5)
            searched = true
        } else if !query.isEmpty {
            await search()
            // 用店名找不到時，改用截圖裡的地址找；韓文地址 Apple 地圖找不到，改用拼音地址找到那條路，再列出那附近的店家。
            if candidates.isEmpty, !screenshotAddress.isEmpty {
                let address = screenshotAddress
                if address != query {
                    query = address
                    await search()
                }
                if candidates.isEmpty, let roman = ScreenshotText.romanizedKoreanAddress(address) {
                    let areas: SearchAreas = if let tripID { await repository.searchAreas(of: tripID) } else { .none }
                    if let street = await placeSearch.search(roman, in: areas, limit: 1).first {
                        let near = await placeSearch.nearby(Coordinate(latitude: street.draft.latitude, longitude: street.draft.longitude), limit: 8)
                        candidates = near.isEmpty ? [street] : near
                        searched = true
                    }
                }
            }
        }
    }

    /// 進行中或即將開始的 Trip 優先。
    public static func defaultTrip(_ trips: [Trip]) -> Trip? {
        let today = LocalDate.string(from: Date(), timeZone: .current)
        return trips.filter { $0.endDate >= today }.min { $0.startDate < $1.startDate } ?? trips.first
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        selected = nil
        matches = []
        withdrawPending()
        let areas: SearchAreas = if let repository, let tripID { await repository.searchAreas(of: tripID) } else { .none }
        candidates = await placeSearch.search(text, in: areas, limit: 6)
        searched = true
    }

    private func discoverScreenshot() async {
        guard let discoveryRepository, !discovering else { return }
        let clue = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clue.count >= 2 else {
            awaitingScreenshotResult = false
            return
        }
        awaitingScreenshotResult = true
        discovering = true
        defer {
            discovering = false
            awaitingScreenshotResult = false
        }
        do {
            discovered = try await discoveryRepository.discoverPlaces(query: clue,
                context: recognizedLines.joined(separator: "\n"))
            if !discovered.isEmpty { country = "KR" }
            if discovered.count == 1, let match = discovered.first, query == clue {
                query = match.koreanName ?? match.name
                if let address = match.addressLocal { screenshotAddress = address }
                discoveryMessage = match.addressLocal == nil
                    ? "已帶入查得的店名；地址尚無可核對的來源，請確認分店。"
                    : "已帶入查得的店名與韓文地址；請確認分店。"
                await search()
            } else {
                discoveryMessage = discovered.isEmpty ? "目前沒有足夠來源可列出店家，原始截圖線索仍可搜尋。" : nil
                if discovered.isEmpty { await search() }
            }
        } catch let error as PlaceDiscoveryError {
            discoveryMessage = error.userMessage
        } catch {
            discoveryMessage = "韓文店名暫時無法查找：\(userMessage(for: error))"
        }
    }

    private func routePoint(_ option: PlaceOption) -> RoutePoint {
        RoutePoint(coordinate: Coordinate(latitude: option.draft.latitude, longitude: option.draft.longitude), countryCode: option.draft.countryCode)
    }

    private func computeMatches() async {
        guard let repository, let tripID, let selected else { return }
        computing = true
        defer { computing = false }
        pending = nil
        do {
            let days = try await repository.days(of: tripID)
            var results: [DayMatch] = []
            for day in days {
                dayTitles[day.id] = "第 \(day.displayOrder + 1) 天"
                let plan = try await repository.loadDayPlan(tripID: tripID, dayID: day.id)
                results.append(await matcher.match(RouteCandidate(point: routePoint(selected), dwellMinutes: category.defaultDwellMinutes),
                                                   into: plan, mode: day.transportMode))
            }
            matches = results
        } catch {
            errorMessage = "無法讀取行程：\(userMessage(for: error))"
        }
    }

    private func propose(_ match: DayMatch) async {
        guard let repository, let tripID, let selected else { return }
        busy = true
        defer { busy = false }
        do {
            let place = try await repository.upsertPlace(confirmedDraft(selected))
            let flow = AddToDayFlow(service: repository, matcher: matcher)
            point = routePoint(selected)
            let (fresh, _) = try await flow.propose(placeID: place.id, label: place.displayTitle, point: point!,
                                                    dwellMinutes: category.defaultDwellMinutes, tripID: tripID, dayID: match.dayID, mode: match.mode)
            pending = fresh
            notice = nil
            if fresh == nil { errorMessage = "以最新行程重新計算後無法估算，可以先收藏。" }
        } catch {
            errorMessage = "無法建立加入要求：\(userMessage(for: error))"
        }
    }

    private func confirm() async {
        guard let repository, let current = pending, let point else { return }
        busy = true
        defer { busy = false }
        do {
            switch try await AddToDayFlow(service: repository, matcher: matcher).confirm(current, point: point) {
            case .added:
                onFinish(.added)
            case .needsReconfirm(let fresh):
                pending = fresh
                notice = "行程剛被其他人修改，這是重新計算的結果，請再確認一次。"
            case .noLongerAvailable:
                pending = nil
                errorMessage = "行程剛被其他人修改，重新計算後無法估算，可以先收藏。"
            }
        } catch {
            errorMessage = "加入失敗：\(userMessage(for: error))"
        }
    }

    private func save() async {
        guard let repository, let tripID else { return }
        busy = true
        defer { busy = false }
        do {
            var placeID: UUID?
            var label = query.trimmingCharacters(in: .whitespaces)
            if let selected {
                let place = try await repository.upsertPlace(confirmedDraft(selected))
                placeID = place.id
                label = place.displayTitle
            }
            let source = SavedSource(url: analysis.sourceURL?.absoluteString, canonicalUrl: analysis.canonicalURL, summary: analysis.excerpt)
            let (_, duplicate) = try await repository.savePlace(tripID: tripID, label: label, category: category, placeID: placeID, source: source)
            onFinish(.saved(duplicate: duplicate))
        } catch {
            errorMessage = "收藏失敗：\(userMessage(for: error))"
        }
    }
}
