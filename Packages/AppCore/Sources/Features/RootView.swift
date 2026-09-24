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
        TabView {
            TodayView(session: session, store: tripStore(session), onDebug: debugAction)
                .tabItem { Label("Today", systemImage: "sun.max") }
            TripListView(session: session)
                .tabItem { Label("Trip", systemImage: "calendar") }
            TripMapView(session: session, store: tripStore(session))
                .tabItem { Label("Map", systemImage: "map") }
            SavedView(session: session)
                .tabItem { Label("Saved", systemImage: "bookmark") }
            ShoppingTab(session: session)
                .tabItem { Label("Shopping", systemImage: "bag") }
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
                        Button("Debug", systemImage: "ladybug", action: onDebug)
                    }
                }
        }
    }
}

#Preview {
    RootView(session: nil)
}
