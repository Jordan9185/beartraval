import AppCore
import ShareCore
import SwiftUI

/// 新增、移動、移除分開預覽；修改原站需另行勾選，固定站由後端保護。
struct TripAIPlanView: View {
    let session: SessionModel
    let trip: Trip
    let onApplied: () -> Void
    @State private var snapshot: TripSnapshot?
    @State private var suggestions: [AssistantAnswer.Arrangement] = []
    @State private var selected: Set<Int> = []
    @State private var beforeStops: [Int: UUID] = [:]
    @State private var instruction = ""
    @State private var message: String?
    @State private var loading = false
    @State private var applying = false
    @State private var submitted: [ArrangementAction]?
    @State private var operationID = UUID()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("整體安排") {
                Text("AI 比較整趟旅程。商品沒有適合原路線的販售店時，保留待買；不會為採買新增跨區行程。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("補充要求，例如某項改到第二天", text: $instruction, axis: .vertical)
                    .disabled(submitted != nil)
                Button(loading ? "AI 正在整理…" : "取得／更新建議") { Task { await load() } }
                    .disabled(loading || applying || submitted != nil)
                if let message { Text(message) }
            }
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                ArrangementSuggestionRow(
                    title: operationLabel(item) + title(item), day: day(item), reason: item.reason,
                    impact: item.kind.hasPrefix("stop_") ? changeImpact(item) : nil,
                    preview: positionPreview(item, index: index), stops: originalStops(item),
                    isRemoval: item.kind == "stop_remove", locked: submitted != nil,
                    selected: Binding(get: { selected.contains(index) }, set: { if $0 { selected.insert(index) } else { selected.remove(index) } }),
                    beforeStop: Binding(get: { beforeStops[index] }, set: { beforeStops[index] = $0 }))
            }
            if !selected.isEmpty {
                Section {
                    Button(applying ? "確認中…" : "確認安排選定 \(selected.count) 項") { Task { await apply() } }
                        .disabled(applying || loading)
                } footer: { Text("只有選定項目進共同旅程；未選項目保留收藏／待買。同一位置的多個新增項目依畫面順序插入。移動／移除只有勾選後才會執行。") }
            }
        }
        .navigationTitle("AI 安排建議")
        .task { await load() }
    }

    private func title(_ item: AssistantAnswer.Arrangement) -> String {
        if item.kind.hasPrefix("stop_") { return sourceStop(item)?.rawLabel ?? "原行程" }
        if item.kind == "saved" { return snapshot?.saved.first { $0.id.uuidString.lowercased() == item.item_id }?.title ?? "收藏" }
        return snapshot?.shopping.first { $0.id.uuidString.lowercased() == item.item_id }?.item.name ?? "商品"
    }
    private func day(_ item: AssistantAnswer.Arrangement) -> String {
        snapshot?.timeline.first { $0.id.uuidString.lowercased() == item.day_id }?.day.localDate ?? "日期待確認"
    }
    private func operationLabel(_ item: AssistantAnswer.Arrangement) -> String {
        switch item.kind { case "stop_move": "移動 · "; case "stop_remove": "移除 · "; default: "新增 · " }
    }
    private func sourceStop(_ item: AssistantAnswer.Arrangement) -> Stop? {
        snapshot?.timeline.flatMap(\.stops).first { $0.id.uuidString.lowercased() == item.item_id }
    }
    private func changeImpact(_ item: AssistantAnswer.Arrangement) -> String {
        guard let snapshot, let stop = sourceStop(item), let sourceDay = snapshot.timeline.first(where: { $0.id == stop.dayId }) else { return "原行程已變更，請重新取得建議。" }
        let names = snapshot.shopping.filter { $0.item.plannedStopId == stop.id || ($0.extraVisits ?? []).contains { $0.id == stop.id } }.map { $0.item.name }
        let prefix = item.kind == "stop_remove" ? "將從第 \(sourceDay.day.displayOrder + 1) 天移除此站，收藏與商品保留。" : "將從第 \(sourceDay.day.displayOrder + 1) 天移至 \(day(item))，原時間與停留長度保留。"
        return prefix + (names.isEmpty ? "" : " 影響採買：" + names.joined(separator: "、"))
    }
    private func originalStops(_ item: AssistantAnswer.Arrangement) -> [Stop] {
        snapshot?.timeline.first { $0.id.uuidString.lowercased() == item.day_id }?.stops.filter { $0.id.uuidString.lowercased() != item.item_id } ?? []
    }
    private func positionPreview(_ item: AssistantAnswer.Arrangement, index: Int) -> String {
        if item.kind == "stop_remove" { return "確認後移除此站，不刪除來源收藏或商品。" }
        let stops = originalStops(item)
        let position = beforeStops[index].flatMap { id in stops.firstIndex { $0.id == id } } ?? stops.count
        let previous = position > 0 ? stops[position - 1].rawLabel : "當日開始"
        let next = position < stops.count ? stops[position].rawLabel : "當日結束"
        return "位置預覽：\(previous) → \(operationLabel(item))\(title(item)) → \(next)"
    }
    private func load() async {
        beforeStops = [:]; suggestions = []; selected = []
        loading = true
        defer { loading = false }
        do {
            snapshot = try await session.trips.snapshot(of: trip)
            let result = try await session.trips.ask(tripID: trip.id,
                question: "請為這趟旅程尚未安排的收藏與商品彙整 arrangements，逐項附日期與理由。有地址線索但無座標仍可建議。商品必須有既有同區域站點，找不到保留未安排，不新增跨區。預設只提出新增；只有補充要求明確要求調整原站時才提出 stop_move／stop_remove，item_id 是原站 ID，固定站不可改動。補充要求：\(instruction)", today: nil, routeFacts: [])
            switch result {
            case .answered(let answer): suggestions = answer.arrangements ?? []; selected = Set(suggestions.indices.filter { !suggestions[$0].kind.hasPrefix("stop_") }); message = answer.answer
            case .failed(let reason): message = PersonalAI.waitingMessage(reason) ?? "尚未取得建議，原始清單仍保留。"
            }
        } catch { message = userMessage(for: error) }
    }
    private func apply() async {
        guard let snapshot else { return }
        applying = true
        defer { applying = false }
        do {
            if submitted == nil {
                var actions: [ArrangementAction] = []
                for index in selected.sorted() {
                    let suggestion = suggestions[index]
                    guard let itemID = UUID(uuidString: suggestion.item_id), let dayID = UUID(uuidString: suggestion.day_id) else { continue }
                    if suggestion.kind.hasPrefix("stop_"), let stop = sourceStop(suggestion), !stop.fixed {
                        actions.append(ArrangementAction(kind: suggestion.kind, itemID: itemID, dayID: dayID,
                            beforeStopID: suggestion.kind == "stop_remove" ? nil : beforeStops[index], sourceDayID: stop.dayId))
                    } else if suggestion.kind == "saved" {
                        actions.append(ArrangementAction(kind: "saved", itemID: itemID, dayID: dayID, beforeStopID: beforeStops[index]))
                    } else if let entry = snapshot.shopping.first(where: { $0.id == itemID }),
                              entry.item.savedStoreSuggestions.filter({ $0.sourceURL == suggestion.source_url }).count == 1,
                              let candidateIndex = entry.item.savedStoreSuggestions.firstIndex(where: { $0.sourceURL == suggestion.source_url }) {
                        actions.append(ArrangementAction(kind: "shopping", itemID: itemID, dayID: dayID,
                            candidateIndex: candidateIndex, candidate: entry.item.savedStoreSuggestions[candidateIndex], beforeStopID: beforeStops[index]))
                    }
                }
                guard actions.count == selected.count else { message = "店家或日期已更新，請重新取得建議。"; return }
                submitted = actions
            }
            try await session.trips.confirmArrangements(tripID: trip.id, actions: submitted ?? [],
                revisions: Dictionary(uniqueKeysWithValues: snapshot.timeline.map { ($0.id.uuidString.lowercased(), $0.day.routeRevision) }), operationID: operationID)
            onApplied(); dismiss()
        } catch BackendError.staleRevision {
            submitted = nil; operationID = UUID(); suggestions = []; selected = []
            message = "旅伴已修改行程。這批沒有寫入；請重新取得建議並確認。"
        } catch let error as BackendError {
            if case .other = error {
                message = "尚未確認結果：\(userMessage(for: error))。可重按確認查回同一次結果，不會重複新增。"
            } else {
                submitted = nil; operationID = UUID(); suggestions = []; selected = []
                message = "這批沒有寫入：\(userMessage(for: error))。請重新取得建議。"
            }
        } catch {
            message = "尚未確認結果：\(userMessage(for: error))。可重按確認查回同一次結果，不會重複新增。"
        }
    }
}

/// 拆成非泛型列，避免 Release 清單層層巢狀造成主執行緒堆疊過深。
private struct ArrangementSuggestionRow: View {
    let title: String
    let day: String
    let reason: String
    let impact: String?
    let preview: String
    let stops: [Stop]
    let isRemoval: Bool
    let locked: Bool
    @Binding var selected: Bool
    @Binding var beforeStop: UUID?
    var body: some View {
        Section {
            Toggle(isOn: $selected) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(day).font(.subheadline)
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(locked)
            if let impact { Text(impact).font(.caption).foregroundStyle(.orange) }
            if selected {
                if !isRemoval {
                    Picker("安排位置", selection: $beforeStop) {
                        Text("當日最後").tag(nil as UUID?)
                        ForEach(stops) { stop in Text("在「\(stop.rawLabel)」之前").tag(Optional(stop.id)) }
                    }.disabled(locked)
                }
                Text(preview).font(.caption)
                Text("未選原站與固定時間保留；同店已有站點則沿用原位。交通及時間衝突未估算，請核對後確認。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
