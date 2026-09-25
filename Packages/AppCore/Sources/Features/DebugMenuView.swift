import SwiftUI

/// Spike 用的除錯工具（只在 DEBUG build 出現）。
struct DebugMenuView: View {
    let session: SessionModel

    var body: some View {
        NavigationStack {
            List {
                Section("帳號") {
                    if case .signedIn(let email) = session.state {
                        LabeledContent("電子郵件", value: email ?? "（未提供）")
                    }
                    Button("登出", role: .destructive) { Task { await session.signOut() } }
                }
                NavigationLink("分享內容紀錄（#2）") { PayloadInspectorListView() }
                NavigationLink("路線／AI 呼叫統計") { TelemetryView() }
                NavigationLink("Naver／Kakao 外開連結（#1）") { LocalMapLinkDebugView() }
            }
            .navigationTitle("除錯")
        }
    }
}
