import AppCore
import ShareCore
import Network
import Observation
import SwiftUI

/// 網路狀態：離線時顯示提示，並改用唯讀快取（決策 D6）。
@MainActor
@Observable
public final class NetworkMonitor {
    public private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnline = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "beartravel.network"))
    }
}

/// 帳號設定：顯示名稱、登出、刪除帳號（App Review 要求 App 內可刪除帳號）。
struct AccountView: View {
    let session: SessionModel
    @State private var name = ""
    @State private var savedName = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var errorMessage: String?
    @AppStorage("navigationApp") private var navigationApp: String = NavigationApp.apple.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if case .signedIn(let email) = session.state {
                    Section("帳號") { LabeledContent("電子郵件", value: email ?? "") }
                }
                Section {
                    HStack {
                        TextField("旅伴看到的名稱", text: $name)
                        Button("儲存") { Task { await saveName() } }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                            .buttonStyle(.borderless)
                    }
                } header: {
                    Text("顯示名稱")
                } footer: {
                    Text(savedName ? "已儲存。" : "旅伴在成員列表和收藏裡看到的名字。")
                }
                Section {
                    Picker("導航用的地圖", selection: $navigationApp) {
                        ForEach(NavigationApp.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                    }
                } header: {
                    Text("導航")
                } footer: {
                    Text("按「導航」時開啟的 App。沒有安裝 Google 地圖時會開網頁版。韓國地點另外提供 Naver／Kakao 地圖。")
                }
                Section {
                    Button("登出") { Task { await session.signOut(); dismiss() } }
                }
                Section {
                    Button(deleting ? "刪除中…" : "刪除帳號", role: .destructive) { confirmDelete = true }.disabled(deleting)
                } footer: {
                    Text("你擁有的旅程會轉給其他成員；沒有其他成員的旅程會一併刪除。你在共同旅程新增的內容會保留給旅伴，但不再顯示你的名字。")
                }
                if let errorMessage { ErrorText(errorMessage) }
            }
            .navigationTitle("設定")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
            .task { if name.isEmpty { name = await session.trips.myDisplayName() ?? "" } }
            .onChange(of: name) { savedName = false }
            .confirmationDialog("確定要刪除帳號？此動作無法復原。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除帳號", role: .destructive) { Task { await deleteAccount() } }
            }
        }
    }

    private func saveName() async {
        do {
            try await session.trips.setDisplayName(name)
            savedName = true
            errorMessage = nil
        } catch let e as BackendError {
            errorMessage = e.userMessage
        } catch {
            errorMessage = "儲存失敗，請稍後再試。"
        }
    }

    private func deleteAccount() async {
        deleting = true
        defer { deleting = false }
        do {
            try await session.trips.deleteAccount()
            await session.signOut()
            dismiss()
        } catch let e as BackendError {
            errorMessage = e == .unauthenticated ? e.userMessage : "刪除沒有完成，請再按一次「刪除帳號」。"
        } catch {
            errorMessage = "刪除沒有完成，請再按一次「刪除帳號」。"
        }
    }
}

/// Debug：路線與 AI 呼叫的延遲、錯誤統計（WP11 可觀測性）。
struct TelemetryView: View {
    @State private var stats: [String: Telemetry.Stats] = [:]

    var body: some View {
        List {
            if stats.isEmpty { Text("尚無資料").foregroundStyle(.secondary) }
            ForEach(stats.keys.sorted(), id: \.self) { key in
                let s = stats[key]!
                Section(key) {
                    LabeledContent("次數", value: "\(s.count)")
                    LabeledContent("延遲 p50／p95", value: "\(s.p50.map { "\($0)" } ?? "-")／\(s.p95.map { "\($0)" } ?? "-") ms")
                    ForEach(s.failures.keys.sorted(), id: \.self) { reason in
                        LabeledContent("失敗：\(reason)", value: "\(s.failures[reason]!)")
                    }
                }
            }
        }
        .navigationTitle("呼叫統計")
        .toolbar { Button("清除") { Task { await Telemetry.shared.reset(); stats = [:] } } }
        .task { stats = await Telemetry.shared.stats }
    }
}
