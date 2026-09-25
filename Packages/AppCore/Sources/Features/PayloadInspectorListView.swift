import ShareCore
import SwiftUI

/// 列出 Share Extension 記錄的 payload，並可匯出 JSON（issue #2）。
struct PayloadInspectorListView: View {
    @State private var records: [PayloadRecord] = []
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    private let store = PayloadLogStore.shared()

    var body: some View {
        List {
            if store == nil {
                Text("App Group 未設定，Extension 無法寫入紀錄。請檢查簽章與 entitlements。")
                    .foregroundStyle(.red)
            }
            if let errorMessage {
                ErrorText(errorMessage)
            }
            ForEach(records) { record in
                NavigationLink {
                    PayloadRecordDetailView(record: record)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.sourceLabel ?? "（未標記來源）").font(.headline)
                        Text(record.capturedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(summary(record)).font(.caption.monospaced())
                    }
                }
            }
        }
        .overlay {
            if records.isEmpty && store != nil {
                ContentUnavailableView("尚無紀錄", systemImage: "tray", description: Text("從 Threads／IG 分享到 BeaRTravel 後回來這裡查看。"))
            }
        }
        .navigationTitle("分享內容紀錄")
        .toolbar {
            if let exportURL {
                ShareLink(item: exportURL) { Label("匯出", systemImage: "square.and.arrow.up") }
            }
            Button("清除", role: .destructive) {
                try? store?.removeAll()
                reload()
            }
        }
        .refreshable { reload() }
        .onAppear { reload() }
    }

    private func reload() {
        guard let store else { return }
        do {
            records = try store.all()
            exportURL = records.isEmpty ? nil : try store.exportFile()
            errorMessage = nil
        } catch {
            errorMessage = "讀取失敗：\(error.localizedDescription)"
        }
    }

    private func summary(_ record: PayloadRecord) -> String {
        let types = record.items.flatMap(\.attachments).flatMap(\.registeredTypeIdentifiers)
        return types.isEmpty ? "無 attachment" : types.joined(separator: ", ")
    }
}

struct PayloadRecordDetailView: View {
    let record: PayloadRecord

    var body: some View {
        List {
            Section("環境") {
                LabeledContent("OS", value: record.osVersion)
                LabeledContent("總耗時", value: "\(record.totalDurationMs) ms")
            }
            ForEach(Array(record.items.enumerated()), id: \.offset) { index, item in
                Section("Item \(index)") {
                    if let title = item.attributedTitle { LabeledContent("title", value: title) }
                    if let text = item.attributedContentText { LabeledContent("contentText", value: text) }
                    ForEach(Array(item.attachments.enumerated()), id: \.offset) { _, attachment in
                        ForEach(Array(attachment.loads.enumerated()), id: \.offset) { _, load in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(load.typeIdentifier).font(.caption.monospaced().bold())
                                Text("\(load.kind.rawValue) · \(load.durationMs) ms" + (load.byteCount.map { " · \($0) B" } ?? ""))
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let preview = load.preview { Text(preview).font(.caption).textSelection(.enabled) }
                                if let error = load.error { Text(error).font(.caption).foregroundStyle(.red) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(record.sourceLabel ?? "紀錄")
    }
}
