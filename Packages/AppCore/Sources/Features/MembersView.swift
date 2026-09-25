import AppCore
import SwiftUI

/// 成員與邀請（§3.3、決策 D5：只有 Owner 可邀請）。
struct MembersView: View {
    let session: SessionModel
    let trip: Trip
    let myRole: TripRole?
    @State private var members: [TripMember] = []
    @State private var inviteRole: TripRole = .editor
    @State private var inviteURL: URL?
    @State private var appURL: URL?
    @State private var myName = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("成員") {
                ForEach(members) { member in
                    HStack {
                        Text(member.displayName + (member.userID == session.trips.currentUserID ? "（你）" : ""))
                        Spacer()
                        if myRole?.canManageMembers == true && member.role != .owner {
                            Menu(member.role.displayName) {
                                ForEach([TripRole.editor, .viewer], id: \.self) { role in
                                    Button(role.displayName) { Task { await setRole(member, role) } }
                                }
                                Button("移除", role: .destructive) { Task { await remove(member) } }
                            }
                        } else {
                            Text(member.role.displayName).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if myRole?.canManageMembers == true {
                Section {
                    Picker("權限", selection: $inviteRole) {
                        Text(TripRole.editor.displayName).tag(TripRole.editor)
                        Text(TripRole.viewer.displayName).tag(TripRole.viewer)
                    }
                    Button("產生邀請連結") { Task { await invite() } }
                    if let inviteURL {
                        ShareLink(item: inviteURL) { Label("分享邀請連結", systemImage: "square.and.arrow.up") }
                        if let appURL {
                            Button("複製 App 連結") {
                                #if canImport(UIKit)
                                UIPasteboard.general.url = appURL
                                #endif
                            }
                        }
                    }
                } header: {
                    Text("邀請")
                } footer: {
                    Text("連結 7 天內有效。預覽頁只顯示旅程名稱、日期與邀請者，不顯示行程內容。")
                }
            }

            Section("我的顯示名稱") {
                HStack {
                    TextField("名稱", text: $myName)
                    Button("儲存") { Task { await saveName() } }.disabled(myName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("成員")
        .task { await reload() }
    }

    private func reload() async {
        do {
            members = try await session.trips.members(of: trip.id)
            myName = members.first { $0.userID == session.trips.currentUserID }?.displayName ?? myName
        } catch {
            errorMessage = "讀取失敗：\(error.localizedDescription)"
        }
    }

    private func invite() async {
        do {
            let token = try await session.trips.createInvite(tripID: trip.id, role: inviteRole)
            if let backend = BackendConfig.fromBundle()?.url { inviteURL = InviteLink.webURL(token: token, backend: backend) }
            appURL = InviteLink.appURL(token: token)
        } catch {
            errorMessage = "無法建立邀請：\(error.localizedDescription)"
        }
    }

    private func setRole(_ member: TripMember, _ role: TripRole) async {
        do { try await session.trips.setMemberRole(tripID: trip.id, userID: member.userID, role: role); await reload() }
        catch { errorMessage = "更新失敗：\(error.localizedDescription)" }
    }

    private func remove(_ member: TripMember) async {
        do { try await session.trips.removeMember(tripID: trip.id, userID: member.userID); await reload() }
        catch { errorMessage = "移除失敗：\(error.localizedDescription)" }
    }

    private func saveName() async {
        do { try await session.trips.setDisplayName(myName); await reload() }
        catch { errorMessage = "儲存失敗：\(error.localizedDescription)" }
    }
}

/// 加入好友的 Trip：貼上邀請連結，或從 beartravel://invite 開啟。
struct JoinTripView: View {
    let session: SessionModel
    let initialToken: String?
    let onJoined: (UUID) -> Void
    @State private var text = ""
    @State private var errorMessage: String?
    @State private var joining = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("貼上邀請連結", text: $text, axis: .vertical)
                } footer: {
                    Text("加入後可依權限查看或編輯共同的收藏、購物清單與行程。")
                }
                Button(joining ? "加入中…" : "加入") { Task { await join() } }
                    .disabled(joining || InviteLink.token(from: text) == nil)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("加入旅程")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear { if let initialToken { text = initialToken } }
        }
    }

    private func join() async {
        guard let token = InviteLink.token(from: text) else { return }
        joining = true
        defer { joining = false }
        do {
            onJoined(try await session.trips.acceptInvite(token: token))
            dismiss()
        } catch let error as BackendError {
            errorMessage = switch error {
            case .gone(let reason): reason == "INVITE_REVOKED" ? "邀請已被撤銷，請向擁有者索取新的邀請。" : "邀請已過期，請向擁有者索取新的邀請。"
            case .notFound: "邀請連結無效。"
            default: "加入失敗：\(error)"
            }
        } catch {
            errorMessage = "加入失敗：\(error.localizedDescription)"
        }
    }
}
