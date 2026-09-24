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
                if turns.isEmpty {
                    Section("可以這樣問") {
                        ForEach(Self.examples, id: \.self) { example in
                            Button(example) { question = example }
                        }
                    }
                }
                ForEach(turns) { turn in
                    Section {
                        Text(turn.question).font(.headline)
                        switch turn.result {
                        case nil:
                            ProgressView("思考中…")
                        case .failed(let reason)?:
                            Text(reason == "missing_api_key" ? "AI 服務尚未設定。" : "暫時無法回答，請稍後再試。").foregroundStyle(.secondary)
                        case .answered(let answer)?:
                            if answer.cannotDetermine {
                                Label("無法從行程資料判斷", systemImage: "questionmark.circle").foregroundStyle(.orange)
                            }
                            Text(answer.answer)
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
           let place = entry.place,
           let day = snapshot.timeline.first(where: { $0.id.uuidString.lowercased() == proposal.dayId.lowercased() }) {
            ProposalReviewView(session: session, tripID: snapshot.trip.id, dayID: day.id, dayTitle: "Day \(day.day.displayOrder + 1)",
                               mode: day.day.transportMode, candidate: SearchResult(draft: place.asDraft),
                               dwellMinutes: entry.saved.category.defaultDwellMinutes, createdByAI: true) {
                applying = nil
                onApplied()
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
        let facts = await routeFacts()
        let today = snapshot.timeline[safe: snapshot.todayIndex()]?.day.localDate
        do {
            turns[index].result = try await session.trips.ask(tripID: snapshot.trip.id, question: text, today: today, routeFacts: facts)
        } catch {
            turns[index].result = .failed(reason: "network")
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
        snapshot.timeline.first { $0.id.uuidString.lowercased() == id.lowercased() }.map { "Day \($0.day.displayOrder + 1)" }
    }

    private func citationName(_ c: AssistantAnswer.Citation) -> String? {
        let id = c.id.lowercased()
        switch c.type {
        case "saved": return savedName(id)
        case "shopping": return snapshot.shopping.first { $0.id.uuidString.lowercased() == id }?.item.name
        case "stop":
            let stop = snapshot.timeline.flatMap(\.stops).first { $0.id.uuidString.lowercased() == id }
            return stop.map { $0.placeId.flatMap { snapshot.places[$0] }.map { $0.nameLocal ?? $0.name } ?? $0.rawLabel }
        case "route_fact": return "順路試算"
        default: return nil
        }
    }
}
