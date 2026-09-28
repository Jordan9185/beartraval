import AppCore
import ShareCore
import SwiftUI

/// AI 助手（規格 §3.7）：只回答本 Trip 的問題並附引用；建議的變更走確認流程（WP5）。
/// Viewer 可以問，但不能套用。
struct AssistantView: View {
    let session: SessionModel
    let snapshot: TripSnapshot
    let canApply: Bool
    let onApplied: () -> Void
    var focusStop: Stop? = nil

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var result: AskResult?
    }

    @State private var question = ""
    @State private var turns: [Turn] = []
    @State private var asking = false
    @State private var applying: AssistantAnswer.Proposal?
    @Environment(\.dismiss) private var dismiss

    static let examples = ["今天下午還能塞什麼？", "誰收藏的店最順路？", "還沒安排的商品哪天買方便？"]

    var body: some View {
        NavigationStack {
            List {
                AIModeSection(session: session)
                if let focusStop {
                    Section("以本站為起點") {
                        Text(focusStop.rawLabel)
                        Text("依到訪日期搜尋；缺少地圖座標仍可查詢。") .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if turns.isEmpty {
                    Section("可以這樣問") {
                        ForEach(focusStop == nil ? Self.examples : ["這附近有什麼甜點？請提供路程、介紹和評分。", "附近有可以使用的廁所嗎？", "到訪當天附近有什麼景點或特殊活動？"], id: \.self) { example in
                            Button(example) { question = example }
                        }
                    }
                }
                ForEach(turns) { turn in
                    Section {
                        Text(turn.question)
                        switch turn.result {
                        case nil:
                            ProgressView("思考中…")
                        case .failed(let reason)?:
                            Text(reason == "missing_api_key" ? "AI 服務尚未設定。"
                                 : PersonalAI.waitingMessage(reason) != nil ? PersonalAI.waitingMessage(reason)! : reason == "rate_limited" ? "AI 使用次數已達上限，請稍後再試。" : "暫時無法回答，請稍後再試。")
                                .foregroundStyle(.secondary)
                        case .answered(let answer)?:
                            if answer.cannotDetermine {
                                Label("無法從行程資料判斷", systemImage: "questionmark.circle").foregroundStyle(.orange)
                            }
                            Text(answer.answer)
                            ForEach(Array((answer.recommendations ?? []).enumerated()), id: \.offset) { _, candidate in
                                RestaurantAnswerRow(candidate: candidate, checkedAt: answer.checkedAt)
                            }
                            if !answer.citations.isEmpty {
                                Text("依據：" + answer.citations.compactMap(citationName).joined(separator: "、"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let proposal = answer.proposal, let name = savedName(proposal.savedId), let day = dayTitle(proposal.dayId) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("建議把「\(name)」加到\(day)", systemImage: "sparkles")
                                    Text(proposal.reason).font(.caption).foregroundStyle(.secondary)
                                    if canApply {
                                        Button("查看並確認…") { applying = proposal }
                                    } else {
                                        Text("僅檢視權限無法套用").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("問這趟旅行的問題", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button("送出") { Task { await ask() } }
                        .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("AI 助手")
            .navigationBarTitleDisplayModeInline()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
            .sheet(item: Binding(get: { applying.map(ApplyTarget.init) }, set: { applying = $0?.proposal })) { target in
                applySheet(target.proposal)
            }
        }
    }

    struct ApplyTarget: Identifiable {
        let proposal: AssistantAnswer.Proposal
        var id: String { proposal.dayId + proposal.savedId }
    }

    @ViewBuilder
    private func applySheet(_ proposal: AssistantAnswer.Proposal) -> some View {
        if let entry = snapshot.saved.first(where: { $0.id.uuidString.lowercased() == proposal.savedId.lowercased() }),
           let day = snapshot.timeline.first(where: { $0.id.uuidString.lowercased() == proposal.dayId.lowercased() }) {
            if let place = entry.place {
            ProposalReviewView(session: session, tripID: snapshot.trip.id, dayID: day.id, dayTitle: "第 \(day.day.displayOrder + 1) 天",
                               mode: day.day.transportMode, candidate: SearchResult(draft: place.asDraft),
                               dwellMinutes: entry.saved.category.defaultDwellMinutes, createdByAI: true) {
                applying = nil
                onApplied()
            }
            } else {
                NavigationStack {
                    SavedScheduleView(session: session, entry: entry) { _ in applying = nil; onApplied() }
                }
            }
        }
    }

    private func ask() async {
        let text = question.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        question = ""
        asking = true
        defer { asking = false }
        turns.append(Turn(question: text))
        let index = turns.count - 1
        let facts: [RouteFact] = [] // AI 先讀行程；路線試算在確認安排時執行，不以地圖成功作為問答前置。
        let today = snapshot.timeline[safe: snapshot.todayIndex()]?.day.localDate
        let started = ContinuousClock.now
        do {
            let result = try await session.trips.ask(tripID: snapshot.trip.id, question: text, today: today, routeFacts: facts, focusStopID: focusStop?.id)
            turns[index].result = result
            var failure: String?
            if case .failed(let reason) = result { failure = reason }
            await Telemetry.shared.record("ai.ask", latencyMs: Int((ContinuousClock.now - started).components.seconds * 1000), failure: failure)
        } catch {
            turns[index].result = .failed(reason: "network")
            await Telemetry.shared.record("ai.ask", latencyMs: Int((ContinuousClock.now - started).components.seconds * 1000), failure: "network")
        }
    }

    /// 在裝置上為已確認的 Saved × 每天算順路，交給 AI 引用（最多 6 個 Saved）。
    private func routeFacts() async -> [RouteFact] {
        var facts: [RouteFact] = []
        for entry in snapshot.routableSaved.prefix(6) {
            guard let place = entry.place else { continue }
            let point = RoutePoint(coordinate: Coordinate(latitude: place.latitude, longitude: place.longitude), countryCode: place.countryCode)
            for day in snapshot.timeline {
                guard let plan = DayPlan.from(day, places: snapshot.places) else { continue }
                let match = await session.routes.match(RouteCandidate(point: point, dwellMinutes: entry.saved.category.defaultDwellMinutes),
                                                       into: plan, mode: day.day.transportMode)
                facts.append(RouteFact(savedID: entry.id, match: match))
            }
        }
        return facts
    }

    private func savedName(_ id: String) -> String? {
        snapshot.saved.first { $0.id.uuidString.lowercased() == id.lowercased() }?.title
    }

    private func dayTitle(_ id: String) -> String? {
        snapshot.timeline.first { $0.id.uuidString.lowercased() == id.lowercased() }.map { "第 \($0.day.displayOrder + 1) 天" }
    }

    private func citationName(_ c: AssistantAnswer.Citation) -> String? {
        let id = c.id.lowercased()
        switch c.type {
        case "saved": return savedName(id)
        case "shopping": return snapshot.shopping.first { $0.id.uuidString.lowercased() == id }?.item.name
        case "stop":
            guard let stop = snapshot.timeline.flatMap(\.stops).first(where: { $0.id.uuidString.lowercased() == id }) else { return nil }
            return stop.placeId.flatMap { snapshot.places[$0] }?.displayTitle(fallbackChinese: stop.rawLabel) ?? stop.rawLabel
        case "route_fact": return "順路試算"
        default: return nil
        }
    }
}

struct RestaurantAnswerRow: View {
    let candidate: AssistantAnswer.Recommendation
    let checkedAt: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.name).font(.headline)
            Text(candidate.introduction)
            Text("路程：" + (candidate.route?.description ?? "無法估算"))
            if let rating = candidate.rating {
                Text("評分：\(rating.display) · \(rating.platform)")
                Text(rating.reviews.map { "評論數：\($0)" } ?? "評論數未取得")
            } else { Text("評分：未取得") }
            Text(candidate.visit_note).font(.caption)
            if let date = checkedAt { Text("查詢時間：\(date)").font(.caption).foregroundStyle(.secondary) }
            sourceLink(candidate.source_url, title: "店家資料來源")
            if let route = candidate.route { sourceLink(route.source_url, title: "路程來源") }
            if let rating = candidate.rating { sourceLink(rating.source_url, title: "評分來源") }
        }
    }
    @ViewBuilder private func sourceLink(_ raw: String, title: String) -> some View {
        if let url = URL(string: raw), url.scheme == "https" { Link(title, destination: url).font(.caption) }
    }
}
