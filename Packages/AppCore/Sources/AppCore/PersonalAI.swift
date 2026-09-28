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
        case "claude_api_not_configured": "共用 Claude API 尚未設定，未切換到其他模式。可選擇本機 GPT 後重試。"
        case "claude_api_running": "Claude API・正在使用共用 API 額度。處理結果會保留在 AI 進度。"
        case "claude_api_error": "Claude API 處理失敗，可能已產生用量。原始需求保留，可自行決定是否重試。"
        case "ai_settings_unavailable": "無法讀取 AI 模式，為避免誤用額度，本次沒有啟動 AI。"
        case "personal_ai_waiting": "已加入處理佇列，可以先離開此頁。請在主畫面的 AI 進度查看狀態；相同需求會沿用已保存的結果。"
        case "personal_ai_running": "仍在處理中，需求已保存。可先離開，在 AI 進度查看完成狀態。"
        case "personal_ai_limit": "GPT 訂閱額度暫時用完，需求已保留，額度恢復後會繼續。"
        case "personal_ai_login": "Mac 上的 ChatGPT 登入需要更新，需求已保留。"
        case "personal_ai_unavailable": "此帳號尚未取得 AI 使用權，請由服務提供者加入可用帳號。"
        case "personal_ai_error": "Mac 上的 GPT 處理未完成，請重試；原始需求已保留。"
        default: nil
        }
    }

    public static func invoke<Response: Decodable>(client: SupabaseClient, function: String,
                                                    options: FunctionInvokeOptions) async throws -> Response {
        var data: Data = try await client.functions.invoke(function, options: options) { data, _ in data }
        let decoder = JSONDecoder()
        let deadline = Date().addingTimeInterval(450)
        while true {
            try Task.checkCancellation()
            let status = try decoder.decode(Status.self, from: data)
            guard ["queued", "running"].contains(status.status), let jobID = status.job_id else {
                return try decoder.decode(Response.self, from: data)
            }
            if Date() >= deadline {
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

public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case localGPT = "local_gpt"
    case claudeAPI = "claude_api"
    public var title: String {
        switch self {
        case .localGPT: "本機 GPT・訂閱額度"
        case .claudeAPI: "Claude API・共用 API 額度"
        }
    }
}

extension TripRepository {
    public func aiProvider() async throws -> AIProvider {
        struct Row: Decodable { let provider: AIProvider }
        do {
            let rows: [Row] = try await client.from("ai_preferences").select("provider").execute().value
            return rows.first?.provider ?? .localGPT
        } catch { throw BackendError.from(error) }
    }
    public func setAIProvider(_ provider: AIProvider) async throws {
        struct Params: Encodable { let p_provider: AIProvider }
        do { try await client.rpc("set_ai_provider", params: Params(p_provider: provider)).execute() }
        catch { throw BackendError.from(error) }
    }
}
