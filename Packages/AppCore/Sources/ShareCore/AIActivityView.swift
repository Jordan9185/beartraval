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
                    Text("使用共用 Mac 的 GPT 服務，Mac 需保持開機連網。這裡只顯示你的工作；其他獲准帳號可能也在排隊，處理時間會變動。")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("AI 處理進度")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .refreshable { await monitor.refresh() }
        }
    }
}
