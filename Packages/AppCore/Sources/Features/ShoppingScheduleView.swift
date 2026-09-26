import AppCore
import ShareCore
import SwiftUI

/// 從有來源的店家候選安排購買；尚未核對地圖定位與商品庫存。
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

    private var selectedDay: TripDay? { days.first { $0.id == selectedDayID } }

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
                }
            }
            if let day = selectedDay {
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
        .navigationTitle("安排購買")
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
            suggestionIndex = loadedItems.first { $0.id == entry.id }?.item.savedStoreSuggestions.firstIndex(of: candidate)
            if !days.contains(where: { $0.id == selectedDayID }) { selectedDayID = days.first?.id }
            if suggestionIndex == nil {
                errorMessage = "這筆店家線索已更新。請返回商品頁重新選擇。"
            } else if days.isEmpty {
                errorMessage = "這趟旅程沒有可安排的日期。"
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = "無法載入旅程：\(userMessage(for: error))"
        }
    }

    private func submit() async {
        guard let day = selectedDay, let suggestionIndex else { return }
        submitting = true
        defer { submitting = false }
        do {
            _ = try await repository.scheduleShoppingStore(
                itemID: entry.id, suggestionIndex: suggestionIndex, sourceURL: candidate.sourceURL,
                dayID: day.id, expectedRouteRevision: day.routeRevision, clientOpID: operationID)
            onScheduled(day.id)
            dismiss()
        } catch BackendError.staleRevision {
            await load()
            errorMessage = "旅伴剛修改了這天行程。請看更新後的日期，再按一次確認。"
        } catch {
            errorMessage = "安排失敗：\(userMessage(for: error))"
        }
    }
}
