import AppCore
import ShareCore
import SwiftUI

/// 再訪由使用者明確安排；原採買站、商品數量及購買歷史維持不變。
struct ShoppingVisitsView: View {
    let repository: TripRepository
    let entry: ShoppingEntry
    let onChanged: () -> Void
    @State private var current: ShoppingEntry?
    @State private var days: [TripDay] = []
    @State private var stops: [Stop] = []
    @State private var dayID: UUID?
    @State private var beforeID: UUID?
    @State private var operationID = UUID()
    @State private var submitted = false
    @State private var busy = false
    @State private var message: String?
    @State private var withdrawal: ShoppingVisit?
    @Environment(\.dismiss) private var dismiss

    private var sourceID: UUID? { current?.item.plannedStopId ?? current?.extraVisits?.first?.id }
    private var source: Stop? { stops.first { $0.id == sourceID } }
    private var dayStops: [Stop] { stops.filter { $0.dayId == dayID }.sorted { $0.sortOrder < $1.sortOrder } }
    var body: some View {
        Form {
            Section("另一次到訪") {
                Text(source?.destinationName ?? current?.item.scheduledStoreName ?? source?.rawLabel ?? "讀取店家中…")
                if let address = source?.destinationAddress ?? current?.item.scheduledStoreAddressLocal {
                    Text(address).font(.caption).textSelection(.enabled)
                }
                Text("保留原本安排，只新增同店的一次到訪。商品需求與已買數量不增加，庫存仍需現場確認。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("到訪日期", selection: $dayID) {
                    Text("請選擇日期").tag(nil as UUID?)
                    ForEach(days) { Text("第 \($0.displayOrder + 1) 天 · \($0.localDate)").tag(Optional($0.id)) }
                }.disabled(submitted || busy)
                Picker("新增位置", selection: $beforeID) {
                    Text("當日最後").tag(nil as UUID?)
                    ForEach(dayStops) { Text("在「\($0.rawLabel)」之前").tag(Optional($0.id)) }
                }.disabled(submitted || busy)
                if dayID != nil {
                    Text(preview).font(.caption)
                    Text("尚未估算交通與固定時段影響；請確認能配合原行程。")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button(busy ? "處理中…" : submitted ? "查回這次安排結果" : "確認新增這次到訪") { Task { await add() } }
                    .disabled(busy || dayID == nil || sourceID == nil)
            }
            if let current, !(current.extraVisits ?? []).isEmpty {
                Section("已追加的到訪") {
                    ForEach(current.extraVisits ?? []) { visit in
                        VStack(alignment: .leading) {
                            Text("第 \(visit.day.displayOrder + 1) 天 · \(visit.stop.rawLabel)")
                            Button("撤回這次到訪") { withdrawal = visit }.disabled(busy || submitted)
                        }
                    }
                }
            }
            if let message { ErrorText(message) }
        }
        .navigationTitle("再訪同一家店")
        .task { await load() }
        .onChange(of: dayID) { beforeID = nil }
        .confirmationDialog("撤回這次追加到訪", isPresented: Binding(get: { withdrawal != nil }, set: { if !$0 { withdrawal = nil } }), titleVisibility: .visible) {
            if let visit = withdrawal {
                Button("解除商品關聯，保留站點") { Task { await remove(visit, removeEmpty: false) } }
                Button("一併移除無其他用途的站點", role: .destructive) { Task { await remove(visit, removeEmpty: true) } }
            }
        } message: { Text("其他到訪、購物清單與已購買紀錄都保留。固定或共用站點不會移除。") }
    }
    private var preview: String {
        let position = beforeID.flatMap { id in dayStops.firstIndex { $0.id == id } } ?? dayStops.count
        let previous = position > 0 ? dayStops[position - 1].rawLabel : "當日開始"
        let next = position < dayStops.count ? dayStops[position].rawLabel : "當日結束"
        return "位置預覽：\(previous) → 再訪 \(source?.rawLabel ?? "店家") → \(next)"
    }
    private func load() async {
        do {
            async let d = repository.days(of: entry.item.tripId)
            async let s = repository.stops(of: entry.item.tripId)
            async let entries = repository.shoppingEntries(of: entry.item.tripId)
            let loaded = try await (d, s, entries)
            days = loaded.0; stops = loaded.1; current = loaded.2.first { $0.id == entry.id }
        } catch { message = userMessage(for: error) }
    }
    private func add() async {
        guard let sourceID, let day = days.first(where: { $0.id == dayID }) else { return }
        busy = true; submitted = true
        defer { busy = false }
        do {
            try await repository.addShoppingVisit(itemID: entry.id, sourceStopID: sourceID, day: day, beforeStopID: beforeID, operationID: operationID)
            onChanged(); dismiss()
        } catch BackendError.staleRevision {
            submitted = false; operationID = UUID(); await load()
            message = "行程或原安排已變更，請重新核對日期與位置後確認。"
        } catch { message = "尚未確認結果：\(userMessage(for: error))。可查回同一次結果，不會重複新增。" }
    }
    private func remove(_ visit: ShoppingVisit, removeEmpty: Bool) async {
        busy = true; defer { busy = false }
        do {
            try await repository.removeShoppingVisit(itemID: entry.id, visit: visit, removeEmpty: removeEmpty)
            withdrawal = nil; onChanged(); await load()
        } catch { message = userMessage(for: error) }
    }
}
