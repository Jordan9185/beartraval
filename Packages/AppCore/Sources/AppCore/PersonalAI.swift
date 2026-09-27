import Foundation
import Supabase

/// 個人 AI 需求先存入雲端，再由 Mac 領取；輪詢不會重新產生工作。
public enum PersonalAI {
    private struct Status: Decodable {
        let status: String
        let job_id: UUID?
        let reason: String?
    }

    private struct Body: Encodable { let action: String; let job_id: UUID }

    public static func waitingMessage(_ reason: String?) -> String? {
        switch reason {
        case "personal_ai_waiting": "需求已保留，等待 Mac 處理。請讓 Mac 保持開機、連網且不要睡眠，稍後重試即可取得結果。"
        case "personal_ai_limit": "GPT 訂閱額度暫時用完，需求已保留，額度恢復後會繼續。"
        case "personal_ai_login": "Mac 上的 ChatGPT 登入需要更新，需求已保留。"
        case "personal_ai_unavailable": "此帳號尚未連接個人 Mac AI。"
        case "personal_ai_error": "Mac 上的 GPT 處理未完成，請重試；原始需求已保留。"
        default: nil
        }
    }

    public static func invoke<Response: Decodable>(client: SupabaseClient, function: String,
                                                    options: FunctionInvokeOptions) async throws -> Response {
        var data: Data = try await client.functions.invoke(function, options: options) { data, _ in data }
        let decoder = JSONDecoder()
        let deadline = Date().addingTimeInterval(450)
        var queuedPolls = 0
        while true {
            try Task.checkCancellation()
            let status = try decoder.decode(Status.self, from: data)
            guard ["queued", "running"].contains(status.status), let jobID = status.job_id else {
                return try decoder.decode(Response.self, from: data)
            }
            queuedPolls = status.status == "queued" ? queuedPolls + 1 : 0
            if Date() >= deadline || queuedPolls >= 5 {
                // 結束前景等待，不取消雲端工作；相同需求重試時會取得同一筆結果。
                let reason = status.reason ?? "personal_ai_waiting"
                let waiting = try JSONSerialization.data(withJSONObject: ["status": "failed", "reason": reason])
                return try decoder.decode(Response.self, from: waiting)
            }
            try await Task.sleep(for: .seconds(3))
            data = try await client.functions.invoke("personal-ai",
                options: FunctionInvokeOptions(body: Body(action: "status", job_id: jobID))) { data, _ in data }
        }
    }
}
