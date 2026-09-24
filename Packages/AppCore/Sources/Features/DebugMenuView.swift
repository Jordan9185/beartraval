import SwiftUI

/// Spike 用的除錯工具（只在 DEBUG build 出現）。
struct DebugMenuView: View {
    let session: SessionModel

    var body: some View {
        NavigationStack {
            List {
                Section("帳號") {
                    if case .signedIn(let email) = session.state {
                        LabeledContent("Email", value: email ?? "（未提供）")
                    }
                    Button("登出", role: .destructive) { Task { await session.signOut() } }
                }
                NavigationLink("Payload Inspector（#2）") { PayloadInspectorListView() }
                NavigationLink("Naver／Kakao 外開連結（#1）") { LocalMapLinkDebugView() }
            }
            .navigationTitle("Debug")
        }
    }
}
