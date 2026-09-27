import AppCore
import SwiftUI

/// 整個 App 共用真實佇列狀態；不假造完成百分比或剩餘秒數。
public struct AIActivityBanner: View {
    let monitor: AIActivityMonitor
    @State private var presented = false
    public init(monitor: AIActivityMonitor) { self.monitor = monitor }

    public var body: some View {
        Button { presented = true } label: {
            HStack(spacing: 8) {
                if !monitor.active.isEmpty { ProgressView() }
                else { Image(systemName: "sparkles") }
                Text(title).font(.caption)
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .accessibilityIdentifier("aiActivityBanner")
        .sheet(isPresented: $presented) { AIActivityList(monitor: monitor) }
    }
    private var title: String {
        let running = monitor.active.filter { $0.status == "running" }.count
        let queued = monitor.active.count - running
        if !monitor.active.isEmpty { return "AI 進度 · \(running) 筆處理中 · \(queued) 筆排隊" }
        if monitor.errorMessage != nil { return "AI 進度 · 暫時無法更新" }
        return "AI 進度 · 目前沒有待處理工作"
    }
}

private struct AIActivityList: View {
    let monitor: AIActivityMonitor
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let error = monitor.errorMessage { Text(error).foregroundStyle(.secondary) }
                if monitor.jobs.isEmpty { Text("目前沒有 AI 處理紀錄。") }
                ForEach(monitor.jobs) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.label.isEmpty ? job.title : job.label).font(.headline)
                        Text(job.statusText).font(.subheadline)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let seconds = job.elapsed(at: context.date) {
                                Text("\(job.isActive ? "已等候" : "總耗時") \(seconds / 60) 分 \(seconds % 60) 秒")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        if let model = job.model { Text(model.replacingOccurrences(of: "codex/", with: "")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    Text("你可以先做其他事，完成後會更新清單。查看進度與已保存的結果不會再次呼叫 AI。")
                    Text("目前使用個人 GPT 模式，Mac 需保持開機連網。排隊順序與處理時間可能變動。")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("AI 處理進度")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .refreshable { await monitor.refresh() }
        }
    }
}
