import AppCore
import ShareCore
import SwiftUI

/// 本人私人旅行紀錄：只能查看與刪除，不會回到任何旅程，也不會分享給旅伴。
struct PrivateHistoryView: View {
    let session: SessionModel
    @State private var records: [PrivateTripHistory] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var pendingDelete: PrivateTripHistory?

    var body: some View {
        List {
            if let errorMessage {
                ErrorText(errorMessage)
                Button("重新載入") { Task { await load() } }
            }
            ForEach(records) { record in
                NavigationLink { PrivateHistoryDetail(record: record) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.trip_name)
                        Text([record.dateRange, record.reasonText].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("刪除", role: .destructive) { pendingDelete = record }
                }
            }
        }
        .overlay {
            if !loaded { ProgressView("載入中…") }
            else if records.isEmpty && errorMessage == nil {
                ContentUnavailableView("沒有私人旅行紀錄", systemImage: "lock.doc",
                    description: Text("退出旅程或旅程被刪除時，你的私人用品與私人採買會留一份在這裡，只有你看得到。"))
            }
        }
        .navigationTitle("私人旅行紀錄")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("刪除「\(pendingDelete?.trip_name ?? "")」的私人紀錄？刪除後無法復原。",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("刪除紀錄", role: .destructive) {
                guard let record = pendingDelete else { return }
                Task {
                    do { try await session.trips.deletePrivateHistory(record.id); records.removeAll { $0.id == record.id } }
                    catch { errorMessage = "刪除未完成：\(userMessage(for: error))" }
                }
            }
        }
    }

    private func load() async {
        do { records = try await session.trips.privateHistory(); errorMessage = nil }
        catch { errorMessage = "無法讀取私人紀錄：\(userMessage(for: error))" }
        loaded = true
    }
}

private struct PrivateHistoryDetail: View {
    let record: PrivateTripHistory
    var body: some View {
        List {
            Section {
                Text("\(record.reasonText)。這是當時你的私人資料副本，只能查看；共同用品與旅伴資料不在此處。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("私人用品") {
                if record.packing.isEmpty { Text("沒有私人用品").foregroundStyle(.secondary) }
                ForEach(Array(record.packing.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Image(systemName: item.packed ? "checkmark.circle.fill" : "circle")
                            .accessibilityLabel(item.packed ? "已裝好" : "未裝好")
                        VStack(alignment: .leading) {
                            Text("\(item.name) × \(item.quantity)")
                            if let note = item.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section("私人採買") {
                if record.purchases.isEmpty { Text("沒有私人採買").foregroundStyle(.secondary) }
                ForEach(Array(record.purchases.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading) {
                        Text(item.name)
                        Text("已買 \(item.bought_quantity)／需要 \(item.desired_quantity) · \(item.purchase_timing == "before_trip" ? "出發前買" : "旅途中買")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(record.trip_name)
    }
}

extension PrivateTripHistory {
    var dateRange: String? {
        guard let start = start_date else { return nil }
        return end_date.map { $0 == start ? start : "\(start)–\($0)" } ?? start
    }
}
