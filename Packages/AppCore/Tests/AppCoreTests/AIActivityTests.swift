import AppCore
import Foundation
import Testing

struct AIActivityTests {
    private func job(status: String, reason: String? = nil) throws -> AIJobActivity {
        var raw: [String: Any] = ["id": UUID().uuidString, "kind": "discover", "status": status,
            "label": "冷麵餐廳", "created_at": "2026-09-27T06:00:00.000+00:00",
            "updated_at": "2026-09-27T06:02:00.000+00:00", "queue_position": 3]
        raw["reason"] = reason
        return try JSONDecoder().decode(AIJobActivity.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    @Test func queuedAndRunningHaveDifferentProgress() throws {
        #expect(try job(status: "queued").statusText == "排隊中 · 我的第 3 筆")
        #expect(try job(status: "running").statusText == "正在查找店家")
        #expect(try job(status: "queued", reason: "personal_ai_limit").statusText == "等待訂閱額度恢復")
        #expect(try job(status: "queued", reason: "personal_ai_login").statusText.contains("重新登入"))
    }
    @Test func completedElapsedTimeStopsAndFailureIsNotCompletion() throws {
        let later = ISO8601DateFormatter().date(from: "2026-09-27T06:05:00Z")!
        #expect(try job(status: "running").elapsed(at: later) == 300)
        #expect(try job(status: "completed").elapsed(at: later) == 120)
        #expect(try job(status: "completed").statusText == "已完成 · 結果已保存")
        #expect(try !job(status: "failed").isActive)
        #expect(try job(status: "failed").statusText.contains("未完成"))
    }
}
