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
    let onFinish: (Outcome) -> Void

    @State private var analysis: ShareAnalysis
    @State private var query: String
    @State private var category: SavedCategory = .place
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
                saveDraft: (() throws -> Void)?, onFinish: @escaping (Outcome) -> Void) {
        self.repository = repository
        self.matcher = matcher
        self.placeSearch = placeSearch
        self.saveDraft = saveDraft
        self.onFinish = onFinish
        let analysis = ShareAnalysis(content)
        _analysis = State(initialValue: analysis)
        _query = State(initialValue: analysis.suggestedQuery ?? "")
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
            } else {
                placeSection
                tripSection
                if selected != nil, tripID != nil { routeSection }
                actionSection
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .task { await start() }
    }

    // MARK: 來源與缺少的資訊

    private var sourceSection: some View {
        Section("分享內容") {
            if let url = analysis.sourceURL {
                LabeledContent(platformName, value: url.host ?? url.absoluteString)
            } else {
                LabeledContent("來源", value: "文字")
            }
            if let excerpt = analysis.excerpt {
                Text(excerpt).font(.callout).lineLimit(4)
            }
            ForEach(Array(analysis.missing.enumerated()), id: \.offset) { _, missing in
                Label(missingText(missing), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
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

    private var placeSection: some View {
        Section {
            HStack {
                TextField("店名或地點", text: $query).onSubmit { Task { await search() } }
                Button("搜尋") { Task { await search() } }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                            .buttonStyle(.borderless)
            }
            Picker("類別", selection: $category) {
                ForEach(SavedCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            ForEach(candidates) { option in
                Button {
                    selected = option
                    Task { await computeMatches() }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(option.displayTitle)
                            if let address = option.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if selected == option { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    }
                }
            }
            if searched && candidates.isEmpty {
                Text("Apple 地圖找不到；仍可先收藏名稱，之後再定位。").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("地點")
        } footer: {
            if selected == nil && !candidates.isEmpty { Text("請選擇正確的店家或分店。") }
        }
    }

    // MARK: Trip 與順路

    private var tripSection: some View {
        Section("加入哪個旅程") {
            if trips.isEmpty {
                Text(signedIn == nil ? "載入中…" : "還沒有旅程，請先在 App 建立。").foregroundStyle(.secondary)
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
                if let notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                Button(busy ? "加入中…" : "確認加入") { Task { await confirm() } }.disabled(busy)
                Button("不加入") { self.pending = nil }
            } else if let best = RouteMatcher.bestDay(matches), let insertion = best.best {
                Text("最適合：\(dayTitles[best.dayID] ?? "")").font(.headline)
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
        guard let repository, await repository.isSignedIn() else { signedIn = false; return }
        do {
            trips = try await repository.myTrips()
            signedIn = true
            tripID = Self.defaultTrip(trips)?.id
        } catch {
            signedIn = false
            return
        }
        if let coordinate = analysis.mapHint?.coordinate, query.isEmpty {
            candidates = await placeSearch.nearby(coordinate, limit: 5)
            searched = true
        } else if !query.isEmpty {
            await search()
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
        pending = nil
        let areas: SearchAreas = if let repository, let tripID { await repository.searchAreas(of: tripID) } else { .none }
        candidates = await placeSearch.search(text, in: areas, limit: 6)
        searched = true
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
            errorMessage = "無法讀取行程：\(error.localizedDescription)"
        }
    }

    private func propose(_ match: DayMatch) async {
        guard let repository, let tripID, let selected else { return }
        busy = true
        defer { busy = false }
        do {
            let place = try await repository.upsertPlace(selected.draft)
            let flow = AddToDayFlow(service: repository, matcher: matcher)
            point = routePoint(selected)
            let (fresh, _) = try await flow.propose(placeID: place.id, label: place.displayTitle, point: point!,
                                                    dwellMinutes: category.defaultDwellMinutes, tripID: tripID, dayID: match.dayID, mode: match.mode)
            pending = fresh
            notice = nil
            if fresh == nil { errorMessage = "以最新行程重新計算後無法估算，可以先收藏。" }
        } catch {
            errorMessage = "無法建立加入要求：\(error.localizedDescription)"
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
            errorMessage = "加入失敗：\(error.localizedDescription)"
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
                let place = try await repository.upsertPlace(selected.draft)
                placeID = place.id
                label = place.displayTitle
            }
            let source = SavedSource(url: analysis.sourceURL?.absoluteString, canonicalUrl: analysis.canonicalURL, summary: analysis.excerpt)
            let (_, duplicate) = try await repository.savePlace(tripID: tripID, label: label, category: category, placeID: placeID, source: source)
            onFinish(.saved(duplicate: duplicate))
        } catch {
            errorMessage = "收藏失敗：\(error.localizedDescription)"
        }
    }
}
