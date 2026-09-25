import SwiftUI

/// 主分頁骨架（Today / Trip / Map / Saved / Shopping）。
///
/// WP1 階段只有空狀態；沒有資料時不顯示假的 Base Route 或示意資料。
public struct RootView: View {
    let session: SessionModel?
    @State private var showsDebug = false
    @State private var store: TripStore?

    /// `session` 為 nil 表示後端設定缺漏（Info.plist 沒有 SupabaseURL／SupabaseAnonKey）。
    public init(session: SessionModel?) {
        self.session = session
    }

    public var body: some View {
        if let session {
            switch session.state {
            case .loading:
                ProgressView()
            case .signedOut:
                LoginView(session: session)
            case .signedIn:
                tabs(session)
                    .sheet(isPresented: Binding(get: { session.pendingInviteToken != nil },
                                                set: { if !$0 { session.pendingInviteToken = nil } })) {
                        JoinTripView(session: session, initialToken: session.pendingInviteToken) { _ in
                            session.pendingInviteToken = nil
                        }
                    }
                    .task { await session.flushOfflineQueue() }
            }
        } else {
            ContentUnavailableView("後端設定缺漏", systemImage: "exclamationmark.triangle",
                                   description: Text("請在 Config/Local.xcconfig.local 設定 SUPABASE_URL 與 SUPABASE_ANON_KEY。"))
        }
    }

    private func tabs(_ session: SessionModel) -> some View {
        tabView(session)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !session.network.isOnline {
                    Label("離線中：顯示最近一次的資料；行程修改需要連線，收藏與購買會在連線後送出。", systemImage: "wifi.slash")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.yellow.opacity(0.25))
                }
            }
            .onChange(of: session.network.isOnline) { _, online in
                if online { Task { await session.flushOfflineQueue(); await store?.reload() } }
            }
    }

    private func tabView(_ session: SessionModel) -> some View {
        TabView {
            TodayView(session: session, store: tripStore(session), onDebug: debugAction)
                .tabItem { Label("今天", systemImage: "sun.max") }
            TripListView(session: session)
                .tabItem { Label("旅程", systemImage: "calendar") }
            TripMapView(session: session, store: tripStore(session))
                .tabItem { Label("地圖", systemImage: "map") }
            SavedView(session: session)
                .tabItem { Label("收藏", systemImage: "bookmark") }
            ShoppingTab(session: session)
                .tabItem { Label("購物", systemImage: "bag") }
        }
        .sheet(isPresented: $showsDebug) { DebugMenuView(session: session) }
        .task {
            if store == nil { store = TripStore(repository: session.trips) }
            await store?.start()
        }
    }

    private func tripStore(_ session: SessionModel) -> TripStore {
        store ?? TripStore(repository: session.trips)
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
                        Button("除錯", systemImage: "ladybug", action: onDebug)
                    }
                }
        }
    }
}

#Preview {
    RootView(session: nil)
}
