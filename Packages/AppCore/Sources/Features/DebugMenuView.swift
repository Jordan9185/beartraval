import SwiftUI

/// Spike 用的除錯工具（只在 DEBUG build 出現）。
struct DebugMenuView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Payload Inspector（#2）") { PayloadInspectorListView() }
                NavigationLink("Naver／Kakao 外開連結（#1）") { LocalMapLinkDebugView() }
            }
            .navigationTitle("Debug")
        }
    }
}
