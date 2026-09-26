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
    let preferredTripID: UUID?
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
    @State private var chosenDiscovery: DiscoveredPlace?
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
    @State private var saveOperationID = UUID()

    public init(content: ShareContent, repository: TripRepository?, matcher: RouteMatcher, placeSearch: any PlaceSearching,
                saveDraft: (() throws -> Void)?, discoveryRepository: InboxRepository? = nil,
                preferredTripID: UUID? = nil,
                onFinish: @escaping (Outcome) -> Void) {
        self.repository = repository
        self.matcher = matcher
        self.placeSearch = placeSearch
        self.saveDraft = saveDraft
        self.discoveryRepository = discoveryRepository
        self.preferredTripID = preferredTripID
        self.onFinish = onFinish
        let analysis = ShareAnalysis(content)
        _analysis = State(initialValue: analysis)
        _query = State(initialValue: analysis.suggestedQuery ?? "")
        _screenshot = State(initialValue: content.imageJPEG)
        // 一開始就標成辨識中，登入檢查那段時間不會先閃出「沒有店名」的提醒。
        _readingScreenshot = State(initialValue: Self.wantsScreenshotText(content.imageJPEG, analysis))
        _awaitingScreenshotResult = State(initialValue: Self.wantsScreenshotText(content.imageJPEG, analysis))
    }

    /// 有截圖就讀圖片線索；貼文標題或搜尋欄可能不是照片中的店名。
    private static func wantsScreenshotText(_ screenshot: Data?, _ analysis: ShareAnalysis) -> Bool {
        screenshot != nil && analysis.mapHint == nil
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
                tripSection
                actionSection
                if selected != nil, tripID != nil { routeSection }
            }
            if let errorMessage { ErrorText(errorMessage) }
        }
        .task { await start() }
        .onChange(of: tripID) { saveOperationID = UUID() }
    }

    // MARK: 來源與缺少的資訊

    private var sourceSection: some View {
        Section("分享內容") {
            Text(analysis.sourceURL?.host.map { platformName == "網頁" ? $0 : "\(platformName) · \($0)" }
                 ?? (screenshot == nil ? "文字" : "截圖"))
                .font(.subheadline).foregroundStyle(.secondary)
            if readingScreenshot { ProgressView("讀取截圖中的文字…") }
            if screenshot != nil || analysis.excerpt != nil {
                DisclosureGroup("查看原始內容") {
                    if let screenshot, let image = platformImage(screenshot) {
                        image.resizable().scaledToFit().frame(maxHeight: 180).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let excerpt = analysis.excerpt {
                        Text(excerpt).font(.subheadline).textSelection(.enabled)
                    }
                }
            }
            if screenshotLines.isEmpty && !readingScreenshot && !awaitingScreenshotResult && query.isEmpty {
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

    /// 原始 OCR 只供修正辨識結果，不佔據主要確認畫面。
    @ViewBuilder
    private var screenshotSuggestions: some View {
        if !screenshotLines.isEmpty {
            DisclosureGroup("改用截圖中的其他文字") {
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
        if screenshot != nil && (country == "KR" || !discovered.isEmpty || discoveryMessage != nil) {
            Section {
                if discovering { ProgressView("正在查店名與地址…") }
                if let discoveryMessage { Text(discoveryMessage).font(.caption).foregroundStyle(.secondary) }
                ForEach(discovered) { suggestion in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(suggestion.koreanName ?? suggestion.name).font(.headline)
                        if let address = suggestion.addressLocal {
                            Text(address).font(.subheadline).textSelection(.enabled)
                        }
                        Button("帶入這間店") {
                            chosenDiscovery = suggestion
                            query = suggestion.koreanName ?? suggestion.name
                            if let address = suggestion.addressLocal { screenshotAddress = address }
                            country = "KR"
                            Task { await search() }
                        }
                        .buttonStyle(.bordered)
                        LocalMapSearchButtons(name: suggestion.searchQuery, countryCode: "KR")
                        DisclosureGroup("查找依據") {
                            Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                            if let url = URL(string: suggestion.sourceURL), url.scheme == "https" {
                                Link("查看網頁來源", destination: url).font(.caption)
                            }
                        }
                    }
                }
                if !discovering && discovered.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("查找可能的韓國店家") { Task { await discoverScreenshot() } }
                }
            } header: {
                Text("AI 查到的店家")
            } footer: {
                Text("地址來自可查看的網頁資料；若要用於行程路線，請另選地圖定位點。")
            }
        }
    }

    @ViewBuilder
    private var placeSection: some View {
        Section("辨識結果") {
            Text(query.isEmpty ? "尚未找到店名" : query).font(.headline)
            if !screenshotAddress.isEmpty {
                Text(screenshotAddress).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let selected {
                Label("已確認定位：\(selected.displayTitle)", systemImage: "mappin.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
            } else if searched {
                Text("尚未確認地圖定位；收藏後可再補，不會計入路線。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("修正店名、地址或類別") {
                PlaceSearchField(text: $query) { Task { await search() } }
                if screenshot != nil {
                    TextField("地址（選填）", text: $screenshotAddress, axis: .vertical)
                        .autocorrectionDisabled()
                    Picker("國家／地區", selection: $country) {
                        Text("看不出來").tag(String?.none)
                        ForEach(Self.countries, id: \.code) { Text($0.name).tag(Optional($0.code)) }
                    }
                    screenshotSuggestions
                }
                Picker("類別", selection: Binding(get: { category }, set: { category = $0; categoryChosen = true })) {
                    ForEach(SavedCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            if searched {
                DisclosureGroup("確認行程定位（\(candidates.count) 個地圖候選）") {
                    ForEach(candidates) { option in
                        Button { toggle(option) } label: {
                            PlaceOptionRow(title: option.displayTitle, address: option.address, selected: selected == option)
                        }
                    }
                    if candidates.isEmpty {
                        Text("地圖暫時找不到定位點；仍可收藏店名。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !query.isEmpty {
                            LocalMapSearchButtons(name: query, countryCode: country ?? LocalMapCountry.guess(name: query + screenshotAddress, timeZone: nil))
                        }
                    }
                }
            }
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
        Group {
            if trips.count > 1 && !trips.contains(where: { $0.id == preferredTripID }) {
                Section("加入哪個旅程") {
                Picker("旅程", selection: $tripID) {
                    ForEach(trips) { Text($0.name).tag(Optional($0.id)) }
                }
                .onChange(of: tripID) { Task { await computeMatches() } }
                }
            } else if trips.isEmpty {
                Section { Text(signedIn == nil ? "載入中…" : "沒有可以新增的旅程。請先建立旅程，或請擁有者給你編輯權限。")
                    .foregroundStyle(.secondary) }
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
            Button(busy ? "處理中…" : "收藏這個地點") { Task { await save() } }
                .disabled(busy || tripID == nil || (selected == nil && query.trimmingCharacters(in: .whitespaces).isEmpty))
        } footer: {
            Text(selected == nil ? "先收藏名稱，定位可之後再補。" : "收藏到旅程的共同清單，不會改動正式行程。")
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
            tripID = trips.first { $0.id == preferredTripID }?.id ?? Self.defaultTrip(trips)?.id
        } catch {
            readingScreenshot = false
            awaitingScreenshotResult = false
            signedIn = false
            return
        }
        // 只要有截圖就讀取店家招牌，避免貼文標題蓋過照片中的實際店名。
        if let screenshot, Self.wantsScreenshotText(screenshot, analysis) {
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
                chosenDiscovery = match
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
            let (saved, duplicate) = try await repository.savePlace(tripID: tripID, label: label, category: category,
                placeID: placeID, source: source, clientOpID: saveOperationID)
            let address = screenshotAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            if address.count >= 3 {
                let matched = chosenDiscovery.flatMap { candidate -> String? in
                    let name = candidate.koreanName ?? candidate.name
                    return query == name && candidate.addressLocal == address ? candidate.sourceURL : nil
                }
                try await repository.setSavedAddressHint(savedID: saved.id, address: address, sourceURL: matched)
            }
            onFinish(.saved(duplicate: duplicate))
        } catch {
            errorMessage = "收藏失敗：\(userMessage(for: error))"
        }
    }
}
