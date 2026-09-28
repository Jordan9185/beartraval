import AppCore
import ShareCore
import SwiftUI

/// 新增、移動、移除分開預覽；修改原站需另行勾選，固定站由後端保護。
struct TripAIPlanView: View {
    let session: SessionModel
    let trip: Trip
    var savedAnswer: AssistantAnswer? = nil
    let onApplied: () -> Void
    @State private var snapshot: TripSnapshot?
    @State private var suggestions: [AssistantAnswer.Arrangement] = []
    @State private var selected: Set<Int> = []
    @State private var requestedTimes: [Int: String] = [:]
    @State private var beforeStops: [Int: UUID] = [:]
    @State private var instruction = ""
    @State private var message: String?
    @State private var loading = false
    @State private var applying = false
    @State private var preview: ArrangementPreview?
    @State private var confirmationAttempted = false
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
                    beforeStop: Binding(get: { beforeStops[index] }, set: { beforeStops[index] = $0 }),
                    requestedTime: Binding(get: { requestedTimes[index] ?? "" }, set: { requestedTimes[index] = $0 }))
            }
            if !selected.isEmpty {
                Section {
                    if preview == nil {
                        Button(applying ? "預覽中…" : "預覽選定 \(selected.count) 項的變更") { Task { await preparePreview() } }
                            .disabled(applying || loading)
                    }
                } footer: { Text("只有選定項目進共同旅程；未選項目保留收藏／待買。同一位置的多個新增項目依畫面順序插入。移動／移除只有勾選後才會執行。") }
            }
            if let preview {
                Section("整日變更預覽") {
                    Text("以下由正式安排規則試排，尚未保存。交通時間及營業狀態未估算，請核對固定事項。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if preview.reusesExistingStop {
                    Text("部分項目已在行程內，會沿用畫面列出的原站與日期，不重複新增或移動。")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(preview.after) { day in
                    ArrangementDayPreview(before: preview.before.first { $0.id == day.id }, after: day)
                }
                Section {
                    Button(applying ? "確認中…" : "確認寫入這批變更") { Task { await apply() } }
                        .disabled(applying || loading)
                    Button("返回修改") { self.preview = nil; submitted = nil; operationID = UUID(); message = nil }
                        .disabled(applying || confirmationAttempted)
                }
            }
        }
        .navigationTitle("AI 安排建議")
        .task {
            if let savedAnswer {
                do {
                    snapshot = try await session.trips.snapshot(of: trip)
                    suggestions = savedAnswer.arrangements ?? []
                    requestedTimes = Dictionary(uniqueKeysWithValues: suggestions.enumerated().map { ($0.offset, $0.element.start_time ?? "") })
                    message = "已載入保存的建議，未重新詢問 AI。請依目前行程重新選擇並預覽。"
                } catch { message = userMessage(for: error) }
            } else { await load() }
        }
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
        let prefix = item.kind == "stop_remove" ? "將從第 \(sourceDay.day.displayOrder + 1) 天移除此站，收藏與商品保留。" : "將從第 \(sourceDay.day.displayOrder + 1) 天移至 \(day(item))，未指定新時間時沿用原時間，停留長度保留。"
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
        beforeStops = [:]; requestedTimes = [:]; suggestions = []; selected = []
        loading = true
        defer { loading = false }
        do {
            snapshot = try await session.trips.snapshot(of: trip)
            let result = try await session.trips.ask(tripID: trip.id,
                question: "請為這趟旅程尚未安排的收藏與商品彙整 arrangements，逐項附日期與理由。有地址線索但無座標仍可建議。商品必須有既有同區域站點，找不到保留未安排，不新增跨區。預設只提出新增；只有補充要求明確要求調整原站時才提出 stop_move／stop_remove，item_id 是原站 ID，固定站不可改動。補充要求：\(instruction)", today: nil, routeFacts: [])
            switch result {
            case .answered(let answer): suggestions = answer.arrangements ?? []; requestedTimes = Dictionary(uniqueKeysWithValues: suggestions.enumerated().map { ($0.offset, $0.element.start_time ?? "") }); selected = Set(suggestions.indices.filter { !suggestions[$0].kind.hasPrefix("stop_") }); message = answer.answer
            case .failed(let reason): message = PersonalAI.waitingMessage(reason) ?? "尚未取得建議，原始清單仍保留。"
            }
        } catch { message = userMessage(for: error) }
    }
    private func preparePreview() async {
        guard let snapshot else { return }
        applying = true
        defer { applying = false }
        do {
            if submitted == nil {
                var actions: [ArrangementAction] = []
                for index in selected.sorted() {
                    let suggestion = suggestions[index]
                    let clock = requestedTimes[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard clock.isEmpty || clock.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil else {
                        message = "請以當地 24 小時制輸入時間，例如 09:30。尚未提交任何安排。"; return
                    }
                    let time: String? = clock.isEmpty ? nil : clock
                    guard let itemID = UUID(uuidString: suggestion.item_id), let dayID = UUID(uuidString: suggestion.day_id) else { continue }
                    if suggestion.kind.hasPrefix("stop_"), let stop = sourceStop(suggestion), !stop.fixed {
                        actions.append(ArrangementAction(kind: suggestion.kind, itemID: itemID, dayID: dayID,
                            beforeStopID: suggestion.kind == "stop_remove" ? nil : beforeStops[index], sourceDayID: stop.dayId, startTime: time))
                    } else if suggestion.kind == "saved" {
                        actions.append(ArrangementAction(kind: "saved", itemID: itemID, dayID: dayID, beforeStopID: beforeStops[index], startTime: time))
                    } else if let entry = snapshot.shopping.first(where: { $0.id == itemID }),
                              entry.item.savedStoreSuggestions.filter({ $0.sourceURL == suggestion.source_url }).count == 1,
                              let candidateIndex = entry.item.savedStoreSuggestions.firstIndex(where: { $0.sourceURL == suggestion.source_url }) {
                        actions.append(ArrangementAction(kind: "shopping", itemID: itemID, dayID: dayID,
                            candidateIndex: candidateIndex, candidate: entry.item.savedStoreSuggestions[candidateIndex], beforeStopID: beforeStops[index], startTime: time))
                    }
                }
                guard actions.count == selected.count else { message = "店家或日期已更新，請重新取得建議。"; return }
                submitted = actions
            }
            preview = try await session.trips.previewArrangements(tripID: trip.id, actions: submitted ?? [],
                revisions: Dictionary(uniqueKeysWithValues: snapshot.timeline.map { ($0.id.uuidString.lowercased(), $0.day.routeRevision) }), operationID: operationID)
            message = "預覽已產生，尚未保存。請核對下方整日行程，再確認寫入。"
        } catch BackendError.staleRevision {
            submitted = nil; operationID = UUID(); suggestions = []; selected = []
            message = "旅伴已修改行程。這批沒有寫入；請重新取得建議並確認。"
        } catch let error as BackendError {
            if case .other = error {
                message = "尚未確認結果：\(userMessage(for: error))。請重試預覽；預覽不會保存安排。"
            } else {
                submitted = nil; operationID = UUID(); suggestions = []; selected = []
                message = "這批沒有寫入：\(userMessage(for: error))。請重新取得建議。"
            }
        } catch {
            message = "尚未確認結果：\(userMessage(for: error))。請重試預覽；預覽不會保存安排。"
        }
    }
    private func apply() async {
        guard let snapshot, let submitted, preview != nil else { return }
        applying = true; confirmationAttempted = true
        defer { applying = false }
        do {
            try await session.trips.confirmArrangements(tripID: trip.id, actions: submitted,
                revisions: Dictionary(uniqueKeysWithValues: snapshot.timeline.map { ($0.id.uuidString.lowercased(), $0.day.routeRevision) }), operationID: operationID)
            onApplied(); dismiss()
        } catch let error as BackendError {
            if error.isTransient {
                message = "尚未確認寫入結果；請重按確認查回這次結果，不能另開一批重送。"
            } else {
                preview = nil; self.submitted = nil; confirmationAttempted = false; operationID = UUID()
                suggestions = []; selected = []; message = "這批未寫入：\(userMessage(for: error))。請重新取得建議。"
            }
        } catch { message = "尚未確認寫入結果，請重按確認查回同一次結果。" }
    }
}

private struct ArrangementDayPreview: View {
    let before: DayTimeline?
    let after: DayTimeline
    var body: some View {
        Section("第 \(after.day.displayOrder + 1) 天 · \(after.day.localDate)") {
            Text("原行程").font(.subheadline.weight(.semibold))
            if let before, !before.stops.isEmpty {
                ForEach(before.stops) { ArrangementPreviewStopRow(stop: $0) }
            } else { Text("尚無安排").foregroundStyle(.secondary) }
            Text("確認後").font(.subheadline.weight(.semibold))
            if after.stops.isEmpty { Text("這一天將沒有安排").foregroundStyle(.secondary) }
            ForEach(after.stops) { ArrangementPreviewStopRow(stop: $0) }
            ForEach(ScheduleTimeReview.issues(in: after.stops)) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            let unknown = ScheduleTimeReview.unknownTimeCount(in: after.stops)
            if unknown > 0 {
                Text("\(unknown) 個站點的時間或停留尚未確定，無法確認是否趕得上；沒有警示不代表交通可行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
private struct ArrangementPreviewStopRow: View {
    let stop: Stop
    var body: some View {
        HStack {
            if stop.fixed { Image(systemName: "lock.fill").accessibilityLabel("固定行程") }
            Text(stop.startTime.map { String($0.prefix(5)) } ?? "時間未定").monospacedDigit()
            Text(stop.destinationName ?? stop.rawLabel)
        }.font(.caption)
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
    @Binding var requestedTime: String
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
                    TextField("指定當地時間（選填，例如 09:30）", text: $requestedTime)
                        .disabled(locked)
                    if !requestedTime.isEmpty {
                        Text("確認時間：\(requestedTime)（所選日期的當地時間）。原結束時間需重新確認，停留長度保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(preview).font(.caption)
                Text("未選原站與固定時間保留；同店已有站點則沿用原位。交通及時間衝突未估算，請核對後確認。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
