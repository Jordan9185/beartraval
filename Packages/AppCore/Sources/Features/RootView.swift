import SwiftUI

/// 主分頁骨架（Today / Trip / Map / Saved / Shopping）。
///
/// WP1 階段只有空狀態；沒有資料時不顯示假的 Base Route 或示意資料。
public struct RootView: View {
    let session: SessionModel?
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsDebug = false
    @State private var store: TripStore?
    /// 還沒有旅程時先停在「旅程」；有旅程時停在「今天」。
    @State private var tab: Tab = .trip
    @State private var choseInitialTab = false

    enum Tab: Hashable { case trip, today, map, saved, shopping }

    /// `session` 為 nil 表示後端設定缺漏（Info.plist 沒有 SupabaseURL／SupabaseAnonKey）。
    public init(session: SessionModel?) {
        self.session = session
    }

    public var body: some View {
        if let session {
            switch session.state {
            case .loading:
                ProgressView("確認登入中…")
            case .signedOut:
                LoginView(session: session)
                    // 換帳號時重建今天／地圖用的資料，不沿用上一個帳號的旅程。
                    .onAppear { store = nil; choseInitialTab = false }
            case .signedIn:
                tabs(session)
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            Task {
                                await session.syncInboxCaptures()
                                await session.resolveInboxPlaces()
                            }
                        }
                    }
                    .sheet(isPresented: Binding(get: { session.pendingInviteToken != nil },
                                                set: { if !$0 { session.pendingInviteToken = nil } })) {
                        JoinTripView(session: session, initialToken: session.pendingInviteToken) { tripID in
                            session.pendingInviteToken = nil
                            tripsChanged(open: tripID, showToday: true)
                        }
                    }
                    .task {
                        await session.flushOfflineQueue()
                        await session.syncInboxCaptures()
                        await session.resolveInboxPlaces()
                        // 雲端工作在分享後才完成時，再查兩次；離開畫面就停止。
                        for _ in 0..<2 {
                            try? await Task.sleep(for: .seconds(12))
                            if Task.isCancelled { break }
                            await session.resolveInboxPlaces()
                        }
                    }
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
                    Label("離線中：顯示最近一次的資料", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.bar)
                }
            }
            .onChange(of: session.network.isOnline) { _, online in
                if online { Task {
                    await session.flushOfflineQueue()
                    await session.syncInboxCaptures()
                    await session.resolveInboxPlaces()
                    await store?.reload()
                } }
            }
    }

    private func tabView(_ session: SessionModel) -> some View {
        TabView(selection: $tab) {
            TripListView(session: session) { tripID, showToday in tripsChanged(open: tripID, showToday: showToday) }
                .tabItem { Label("旅程", systemImage: "calendar") }
                .tag(Tab.trip)
            TodayView(session: session, store: tripStore(session), onDebug: debugAction) { tab = .trip }
                .tabItem { Label("今天", systemImage: "sun.max") }
                .tag(Tab.today)
            TripMapView(session: session, store: tripStore(session)) { tab = .trip }
                .tabItem { Label("地圖", systemImage: "map") }
                .tag(Tab.map)
            SavedView(session: session, preferredTripID: store?.selectedTripID,
                      onOpenDay: { tripID, dayID in
                          store?.selectedTripID = tripID
                          store?.requestedDayID = dayID
                          tab = .today
                      }, onOpenShopping: {
                          tab = .shopping
                      }) { selected in
                store?.selectedTripID = selected
            }
                .tabItem { Label("收藏", systemImage: "bookmark") }
                .tag(Tab.saved)
            ShoppingTab(session: session, preferredTripID: store?.selectedTripID, isSelected: tab == .shopping,
                        onOpenDay: { tripID, dayID in
                            store?.selectedTripID = tripID
                            store?.requestedDayID = dayID
                            tab = .today
                        }) { selected in
                store?.selectedTripID = selected
            }
                .tabItem { Label("購物", systemImage: "bag") }
                .tag(Tab.shopping)
        }
        .onChange(of: store?.loaded) {
            guard !choseInitialTab, let store, store.loaded else { return }
            choseInitialTab = true
            tab = store.trips.isEmpty ? .trip : .today
        }
        .sheet(isPresented: $showsDebug) { DebugMenuView(session: session) }
        .task {
            if store == nil { store = TripStore(repository: session.trips) }
            await store?.start()
        }
    }

    /// 旅程清單有變（建立、加入、刪除）：今天與地圖改用最新資料，不再停在「尚未建立旅程」（審查 H3）。
    private func tripsChanged(open tripID: UUID?, showToday: Bool) {
        Task {
            await store?.open(tripID: tripID)
            if showToday { tab = .today }
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
