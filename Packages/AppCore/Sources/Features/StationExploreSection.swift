import AppCore
import ShareCore
import SwiftUI

struct StationExploreSection: View {
    let session: SessionModel
    let stop: Stop
    let canEdit: Bool
    let automatic: Bool
    let onArrange: (SavedEntry) -> Void
    @State private var answer: AssistantAnswer?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var operationIDs: [String: UUID] = [:]
    @State private var savedIDs: [String: UUID] = [:]
    @State private var saving = false

    var body: some View {
        Section("這一站附近") {
            if loading { ProgressView("AI 正在查到訪當天的附近景點、美食與活動…") }
            if let errorMessage { ErrorText(errorMessage) }
            if let answer {
                Text(answer.answer)
                ForEach(Array((answer.recommendations ?? []).enumerated()), id: \.offset) { index, candidate in
                    StationRecommendationRow(candidate: candidate, checkedAt: answer.checkedAt,
                        canEdit: canEdit, saved: savedIDs[key(candidate)] != nil,
                        save: { Task { await save(candidate, index: index, arrange: false) } },
                        arrange: { Task { await save(candidate, index: index, arrange: true) } })
                }
            }
            Button(answer == nil ? "查詢附近" : "再次查看附近建議") { Task { await load() } }.disabled(loading)
            Text("以本站及到訪日期查詢，不使用手機位置；收藏會加入本旅程共同清單。安排前仍需確認，未查得的路程與評分保留未知。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: stop.id) { if automatic { await load() } }
        .disabled(saving)
    }
    private func key(_ candidate: AssistantAnswer.Recommendation) -> String {
        [candidate.name, candidate.address_local ?? "", candidate.source_url].joined(separator: "\n")
    }
    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await session.trips.ask(tripID: stop.tripId,
                question: "請以本站為中心，搜尋到訪當天附近的熱門景點、美食和特殊活動，附來源與推薦理由。餐飲需路程、介紹及外部評分；無資料保留未知。事件日期不符不要推薦。",
                today: nil, routeFacts: [], focusStopID: stop.id)
            switch result {
            case .answered(let result): answer = result; errorMessage = nil
            case .failed(let reason): errorMessage = PersonalAI.waitingMessage(reason) ?? "暫時無法查詢，原行程仍可使用。"
            }
        } catch { errorMessage = "附近探索暫時無法取得（\(userMessage(for: error))）；原行程不受影響，可稍後按「查詢附近」重試。" }
    }
    private func save(_ candidate: AssistantAnswer.Recommendation, index: Int, arrange: Bool) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let id: UUID
            if let stored = savedIDs[key(candidate)] { id = stored }
            else {
                let operation = operationIDs[key(candidate)] ?? UUID()
                operationIDs[key(candidate)] = operation
                let result = try await session.trips.saveStationPlace(tripID: stop.tripId, candidate: candidate, operationID: operation)
                id = result.id
                savedIDs[key(candidate)] = id
            }
            if arrange {
                if let entry = try await session.trips.savedEntries(of: stop.tripId).first(where: { $0.id == id }) {
                    onArrange(entry)
                } else { errorMessage = "收藏已變更，請重新開啟共同收藏。" }
            }
        } catch { errorMessage = "收藏或安排未完成：\(userMessage(for: error))" }
    }
}
private struct StationRecommendationRow: View {
    let candidate: AssistantAnswer.Recommendation
    let checkedAt: String?
    let canEdit: Bool
    let saved: Bool
    let save: () -> Void
    let arrange: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RestaurantAnswerRow(candidate: candidate, checkedAt: checkedAt)
            if canEdit {
                HStack {
                    Button(saved ? "已收藏" : "先收藏", action: save).disabled(saved)
                    Button("請 AI 安排", action: arrange)
                }.buttonStyle(.borderless)
            }
        }
    }
}
