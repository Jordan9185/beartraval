import AppCore
import SwiftUI

/// 已知時間衝突與路程可行性；行程頁與變更預覽共用。沒有警示不代表交通可行。
struct ScheduleReviewNotes: View {
    let stops: [Stop]
    var legs: [BaseRoute.Leg] = []

    var body: some View {
        let issues = ScheduleTimeReview.issues(in: stops) + ScheduleTimeReview.travelIssues(in: stops, legs: legs)
        ForEach(issues) { issue in
            Label(issue.message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        let unknown = ScheduleTimeReview.unknownTimeCount(in: stops)
        if unknown > 0 {
            Text("\(unknown) 個站點的時間或停留尚未確定，無法確認是否趕得上；沒有警示不代表交通可行。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
