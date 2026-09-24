import SwiftUI

/// 主分頁骨架（Today / Trip / Map / Saved / Shopping）。
///
/// WP1 階段只有空狀態；沒有資料時不顯示假的 Base Route 或示意資料。
public struct RootView: View {
    @State private var showsDebug = false

    public init() {}

    public var body: some View {
        TabView {
            EmptyTab(title: "Today", systemImage: "sun.max", message: "尚未建立行程", onDebug: debugAction)
                .tabItem { Label("Today", systemImage: "sun.max") }
            EmptyTab(title: "Trip", systemImage: "calendar", message: "尚未建立行程")
                .tabItem { Label("Trip", systemImage: "calendar") }
            EmptyTab(title: "Map", systemImage: "map", message: "尚無已確認的地點")
                .tabItem { Label("Map", systemImage: "map") }
            EmptyTab(title: "Saved", systemImage: "bookmark", message: "尚未收藏地點")
                .tabItem { Label("Saved", systemImage: "bookmark") }
            EmptyTab(title: "Shopping", systemImage: "bag", message: "尚未新增商品")
                .tabItem { Label("Shopping", systemImage: "bag") }
        }
        .sheet(isPresented: $showsDebug) { DebugMenuView() }
    }

    /// Spike 工具入口只在 DEBUG build 出現，不佔用分頁。
    private var debugAction: (() -> Void)? {
        #if DEBUG
        { showsDebug = true }
        #else
        nil
        #endif
    }
}

struct EmptyTab: View {
    let title: String
    let systemImage: String
    let message: String
    var onDebug: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ContentUnavailableView(message, systemImage: systemImage)
                .navigationTitle(title)
                .toolbar {
                    if let onDebug {
                        Button("Debug", systemImage: "ladybug", action: onDebug)
                    }
                }
        }
    }
}

#Preview {
    RootView()
}
