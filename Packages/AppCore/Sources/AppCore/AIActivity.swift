import Foundation
import Observation
import Supabase

public struct AIJobActivity: Decodable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: String
    public let status: String
    public let reason: String?
    public let label: String
    public let createdAt: String
    public let updatedAt: String
    public let queuePosition: Int?
    public let model: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, status, reason, label, model
        case createdAt = "created_at", updatedAt = "updated_at", queuePosition = "queue_position"
    }
    public var isActive: Bool { status == "queued" || status == "running" }
    public var title: String {
        switch kind {
        case "parse": "整理行程"
        case "inbox": "辨識分享內容"
        case "discover": "查找店家"
        case "extract": "辨識商品"
        case "ask": "回答旅程問題"
        default: "AI 整理"
        }
    }
    public var statusText: String {
        if isActive && reason == "personal_ai_limit" { return "等待訂閱額度恢復" }
        if isActive && reason == "personal_ai_login" { return "需要在 Mac 重新登入 ChatGPT" }
        switch status {
        case "queued": return "排隊中 · 第 \(queuePosition ?? 1) 筆"
        case "running": return "正在\(title)"
        case "completed": return "已完成 · 結果已保存"
        case "failed": return reason == "superseded" ? "內容已更新，舊工作已停止" : "處理未完成，可回原項目重試"
        default: return "正在取得狀態"
        }
    }
    public func elapsed(at now: Date) -> Int? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
        guard let start else { return nil }
        let end = isActive ? now : formatter.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt) ?? now
        return max(0, Int(end.timeIntervalSince(start)))
    }
}

/// 只讀工作狀態，不啟動 AI；依登入帳號建立，登出清空。
@MainActor @Observable
public final class AIActivityMonitor {
    public private(set) var jobs: [AIJobActivity] = []
    public private(set) var errorMessage: String?
    public private(set) var completionVersion = ""
    private let client: SupabaseClient
    private var generation = UUID()

    public init(client: SupabaseClient) { self.client = client }
    public var active: [AIJobActivity] { jobs.filter(\.isActive) }
    public func reset() {
        generation = UUID()
        jobs = []
        errorMessage = nil
        completionVersion = ""
    }
    public func refresh() async {
        struct Body: Encodable { let action = "activity" }
        struct Response: Decodable { let jobs: [AIJobActivity] }
        let request = generation
        do {
            let response: Response = try await client.functions.invoke("personal-ai", options: FunctionInvokeOptions(body: Body()))
            guard generation == request, !Task.isCancelled else { return }
            jobs = response.jobs
            errorMessage = nil
            completionVersion = jobs.filter { !$0.isActive }.map { "\($0.id):\($0.updatedAt)" }.sorted().joined(separator: "|")
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            errorMessage = "暫時無法更新進度，顯示上次查詢結果。"
        }
    }
    public func watch() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
        }
    }
}
