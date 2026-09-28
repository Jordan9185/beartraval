import AppCore
import ShareCore
import SwiftUI

/// 從有來源的店家候選安排購買；已安排的商品在同一交易換店，先預覽整日變更。尚未核對地圖定位與商品庫存。
struct ShoppingScheduleView: View {
    let repository: TripRepository
    let entry: ShoppingEntry
    let candidate: ShoppingStoreSuggestion
    let onScheduled: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var days: [TripDay] = []
    @State private var stops: [Stop] = []
    @State private var suggestionIndex: Int?
    @State private var selectedDayID: UUID?
    @State private var loading = true
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var operationID = UUID()
    @State private var recommendation: String?
    @State private var asking = false
    @State private var manualOverride = false
    @State private var currentStop: Stop?
    @State private var removeEmptySource = false
    @State private var preview: ArrangementPreview?
    @State private var submittedSwap: ArrangementAction?
    @State private var submittedRevisions: [String: Int] = [:]
    @State private var confirmationAttempted = false

    private var selectedDay: TripDay? { days.first { $0.id == selectedDayID } }
    private var isSwap: Bool { entry.item.plannedStopId != nil }
    private var locked: Bool { submittedSwap != nil }

    var body: some View {
        Form {
            if let errorMessage { ErrorText(errorMessage) }
            Section("想買的商品") {
                Text(entry.item.name).font(.headline)
                Text("店家線索：\(candidate.displayName)")
                if let address = candidate.addressLocal, !address.isEmpty {
                    Text(address).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("可到店詢問；是否販售與庫存未知。")
                    .font(.caption).foregroundStyle(.secondary)
                if let url = URL(string: candidate.sourceURL), url.scheme == "https" {
                    Link("查看店家線索來源", destination: url)
                }
            }
            Section("以既有行程為主") {
                if asking { ProgressView("AI 正在比較原有行程區域…") }
                if let recommendation { Text(recommendation) }
                if !asking && selectedDayID == nil {
                    Text(isSwap ? "目前維持原安排，不為換店新增跨區行程。" : "目前保留待買，不為商品新增跨區行程。")
                    Button(isSwap ? "我仍要換到這間店，查看日期" : "我仍要安排這間店，查看日期") { manualOverride = true }
                }
            }
            if isSwap { currentSection }
            if selectedDayID != nil || manualOverride {
            Section("排在哪一天") {
                if loading { ProgressView("正在載入日期…") }
                ForEach(days) { day in
                    Button {
                        selectedDayID = day.id
                    } label: {
                        HStack {
                            Text("第 \(day.displayOrder + 1) 天 · \(day.localDate)")
                            Spacer()
                            if selectedDayID == day.id { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(locked)
                }
            }
            }
            if isSwap, let day = selectedDay {
                swapSections(day)
            } else if let day = selectedDay {
                Section("排入前確認") {
                    LabeledContent("日期", value: "第 \(day.displayOrder + 1) 天 · \(day.localDate)")
                    Text("這間店尚未確認地圖位置；會先排在當天最後，路線未估算。")
                        .foregroundStyle(.secondary)
                    if stops.contains(where: { $0.dayId == day.id && $0.fixed }) {
                        Text("已固定的行程與時間不會移動。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(submitting ? "排入中…" : "確認安排購買") { Task { await submit() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(submitting || suggestionIndex == nil)
                } footer: {
                    Text("排入後可以再確認店面定位；安排購買不表示店家有貨。")
                }
            }
        }
        .navigationTitle(isSwap ? "換店" : "安排購買")
        .navigationBarTitleDisplayModeInline()
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let dayList = repository.days(of: entry.item.tripId)
            async let stopList = repository.stops(of: entry.item.tripId)
            async let itemList = repository.shoppingEntries(of: entry.item.tripId)
            let (loadedDays, loadedStops, loadedItems) = try await (dayList, stopList, itemList)
            days = loadedDays.sorted { $0.displayOrder < $1.displayOrder }
            stops = loadedStops
            let latest = loadedItems.first { $0.id == entry.id }?.item
            suggestionIndex = latest?.savedStoreSuggestions.firstIndex(of: candidate)
            currentStop = latest?.plannedStopId.flatMap { id in loadedStops.first { $0.id == id } }
            if isSwap && currentStop == nil {
                errorMessage = "這件商品的安排剛被修改。請返回商品頁確認目前狀態。"
                return
            }
            if !days.contains(where: { $0.id == selectedDayID }) { selectedDayID = nil }
            if suggestionIndex == nil {
                errorMessage = "這筆店家線索已更新。請返回商品頁重新選擇。"
            } else if days.isEmpty {
                errorMessage = "這趟旅程沒有可安排的日期。"
            } else {
                errorMessage = nil
                await recommend()
            }
        } catch {
            errorMessage = "無法載入旅程：\(userMessage(for: error))"
        }
    }

    private func recommend() async {
        asking = true
        defer { asking = false }
        do {
            let result = try await repository.ask(tripID: entry.item.tripId,
                question: "請判斷商品 \(entry.id.uuidString.lowercased()) 的候選店 \(candidate.displayName)（\(candidate.sourceURL)）是否適合原有行程。僅回傳有既有同區域站點支持的 shopping_proposal；不順路、只有其他商圈有售或無法判斷時保留待買，不要新增跨區行程。",
                today: nil, routeFacts: [])
            switch result {
            case .answered(let answer):
                recommendation = answer.answer
                if let proposal = answer.shoppingProposal, proposal.item_id == entry.id.uuidString.lowercased(),
                   proposal.source_url == candidate.sourceURL,
                   entry.item.savedStoreSuggestions.filter({ $0.sourceURL == candidate.sourceURL }).count == 1,
                   let id = UUID(uuidString: proposal.day_id), days.contains(where: { $0.id == id }) {
                    selectedDayID = id
                    recommendation = proposal.reason
                }
            case .failed(let reason): recommendation = PersonalAI.waitingMessage(reason) ?? undecided
            }
        } catch { recommendation = undecided }
    }

    @ViewBuilder private var currentSection: some View {
        Section("目前安排") {
            LabeledContent("店家", value: entry.item.scheduledStoreName ?? currentStop?.rawLabel ?? "原採買站")
            if let stop = currentStop, let day = days.first(where: { $0.id == stop.dayId }) {
                LabeledContent("日期", value: "第 \(day.displayOrder + 1) 天 · \(day.localDate)")
            }
            Toggle("原站沒有其他用途時一併移除", isOn: $removeEmptySource).disabled(locked)
            Text("只換這件商品的店與日期。原站若還有其他商品、收藏、固定行程或原本就是一般行程，一律保留；購買數量與紀錄不變。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func swapSections(_ day: TripDay) -> some View {
        if let preview {
            Section("整日變更預覽") {
                Text("以下由正式安排規則試排，尚未保存。新店未定位，路程與營業狀態未估算。")
                    .font(.caption).foregroundStyle(.secondary)
                if preview.reusesExistingStop {
                    Text("新店在當天已有同店同地址的站，會沿用該站，不重複新增。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            ForEach(preview.after) { after in
                ArrangementDayPreview(before: preview.before.first { $0.id == after.id }, after: after)
            }
            Section {
                Button(submitting ? "確認中…" : "確認換店") { Task { await confirmSwap() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(submitting)
                Button("返回修改") { resetSwap() }.disabled(submitting || confirmationAttempted)
            }
        } else {
            Section {
                Button(submitting ? "預覽中…" : "預覽換到第 \(day.displayOrder + 1) 天") { Task { await previewSwap(day) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(submitting || suggestionIndex == nil || currentStop == nil)
            } footer: {
                Text("確認前不會修改行程。換店不表示新店家有貨。")
            }
        }
    }

    private func resetSwap() {
        preview = nil; submittedSwap = nil; submittedRevisions = [:]; confirmationAttempted = false; operationID = UUID()
    }

    private func previewSwap(_ day: TripDay) async {
        guard let suggestionIndex, let stop = currentStop else { return }
        submitting = true
        defer { submitting = false }
        let action = ArrangementAction.shoppingSwap(itemID: entry.id, fromStopID: stop.id, fromDayID: stop.dayId,
            toDayID: day.id, candidateIndex: suggestionIndex, candidate: candidate, removeEmptySource: removeEmptySource)
        let revisions = Dictionary(uniqueKeysWithValues: days.map { ($0.id.uuidString.lowercased(), $0.routeRevision) })
        do {
            preview = try await repository.previewArrangements(tripID: entry.item.tripId, actions: [action],
                                                               revisions: revisions, operationID: operationID)
            submittedSwap = action; submittedRevisions = revisions; errorMessage = nil
        } catch {
            await handleSwapFailure(error)
        }
    }

    private func confirmSwap() async {
        guard let action = submittedSwap else { return }
        submitting = true; confirmationAttempted = true
        defer { submitting = false }
        do {
            try await repository.confirmArrangements(tripID: entry.item.tripId, actions: [action],
                                                     revisions: submittedRevisions, operationID: operationID)
            onScheduled(action.day_id)
            dismiss()
        } catch let error as BackendError where error.isTransient {
            errorMessage = "尚未確認換店結果；請重按確認查回這次結果，不會另開一次換店。"
        } catch {
            await handleSwapFailure(error)
        }
    }

    private func handleSwapFailure(_ error: Error) async {
        resetSwap()
        if case BackendError.staleRevision = error {
            await load()
            errorMessage = "旅伴剛修改了相關日期或這件商品。請看更新後的安排，再重新預覽。"
        } else {
            errorMessage = "換店未完成，原安排保留：\(userMessage(for: error))"
        }
    }

    private var undecided: String { isSwap ? "AI 暫時無法判斷，維持原安排。" : "AI 暫時無法判斷，商品保留待買。" }

    private func submit() async {
        guard let day = selectedDay, let suggestionIndex else { return }
        submitting = true
        defer { submitting = false }
        do {
            let result = try await repository.scheduleShoppingStore(
                itemID: entry.id, suggestionIndex: suggestionIndex, sourceURL: candidate.sourceURL,
                expectedStoreName: candidate.displayName, expectedAddressLocal: candidate.addressLocal,
                dayID: day.id, expectedRouteRevision: day.routeRevision, clientOpID: operationID)
            onScheduled(result.dayID)
            dismiss()
        } catch BackendError.staleRevision {
            await load()
            errorMessage = "旅伴剛修改了這天行程。請看更新後的日期，再按一次確認。"
        } catch {
            errorMessage = "安排失敗：\(userMessage(for: error))"
        }
    }
}
