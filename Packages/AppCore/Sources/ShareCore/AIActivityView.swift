import AppCore
import SwiftUI

/// 從「更多」開啟真實佇列狀態，不以常駐橫條占用主畫面。
public struct AIActivityView: View {
    let monitor: AIActivityMonitor
    @Environment(\.dismiss) private var dismiss
    public init(monitor: AIActivityMonitor) { self.monitor = monitor }
    public var body: some View {
        NavigationStack {
            List {
                if let error = monitor.errorMessage { Text(error).foregroundStyle(.secondary) }
                if monitor.jobs.isEmpty { Text("目前沒有 AI 處理紀錄。") }
                ForEach(monitor.jobs) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.label.isEmpty ? job.title : job.label).font(.headline)
                        Text(job.statusText).font(.subheadline)
                        Text((job.provider ?? .localGPT).title).font(.caption).foregroundStyle(.secondary)
                        Text(job.usageText).font(.caption).foregroundStyle(.secondary)
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
                    Text("本機 GPT 需要 Mac 開機連網；Claude API 使用共用 API 額度且不需要 Mac。這裡只顯示你的工作，模式切換只影響新工作，不會自動重跑或轉用付費 API。")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("AI 處理進度")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .refreshable { await monitor.refresh() }
        }
    }
}
