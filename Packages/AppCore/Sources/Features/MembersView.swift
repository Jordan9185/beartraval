import AppCore
import ShareCore
import SwiftUI

/// 成員與邀請（§3.3、決策 D5：只有 Owner 可邀請）。
struct MembersView: View {
    let session: SessionModel
    let trip: Trip
    let myRole: TripRole?
    @Environment(\.dismiss) private var dismiss
    @State private var currentRole: TripRole?
    @State private var offer: OwnershipOffer?
    @State private var confirmingLeave = false
    @State private var departure: TripDeparturePreview?
    @State private var loadingDeparture = false
    @State private var leaving = false
    @State private var ownershipTarget: TripMember?
    @State private var members: [TripMember] = []
    @State private var inviteRole: TripRole = .editor
    @State private var inviteURL: URL?
    @State private var appURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("成員") {
                ForEach(members) { member in
                    HStack {
                        Text(member.displayName + (member.userID == session.trips.currentUserID ? "（你）" : ""))
                        Spacer()
                        if (currentRole ?? myRole)?.canManageMembers == true && member.role != .owner {
                            Menu(member.role.displayName) {
                                ForEach([TripRole.editor, .viewer], id: \.self) { role in
                                    Button(role.displayName) { Task { await setRole(member, role) } }
                                }
                                if member.role == .editor { Button("邀請接任擁有者") { ownershipTarget = member } }
                                Button("移除", role: .destructive) { Task { await remove(member) } }
                            }
                        } else {
                            Text(member.role.displayName).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if (currentRole ?? myRole)?.canManageMembers == true {
                Section {
                    Text("以可編輯旅伴身分加入；既有僅檢視成員不自動升權。")
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

            if let offer {
                Section("擁有權移交") {
                    if offer.to_user == session.trips.currentUserID {
                        Text("擁有者邀請你接任。接受後可管理成員及刪除旅程，原擁有者改為可編輯旅伴。")
                        Button("接受接任") { Task { await respond(offer, accept: true) } }
                        Button("婉拒") { Task { await respond(offer, accept: false) } }
                    } else {
                        Text("等待對方接受接任；目前的擁有權不變。")
                        Button("取消移交") { Task { await transfer(to: nil) } }
                    }
                }
            }
            Section {
                if (currentRole ?? myRole) == .owner {
                    Text("退出前，請先在成員選單邀請接任；對方接受後才能退出。")
                } else { Button(loadingDeparture ? "正在核對分工…" : "退出這趟旅程", role: .destructive) { Task { await prepareDeparture() } }.disabled(loadingDeparture) }
            } footer: {
                Text("共同內容與已完成紀錄留給旅伴；未完成分工回待認領。私人來源及用品不轉公開，退出後無法修改該旅程。")
            }
            if let errorMessage { ErrorText(errorMessage) }
        }
        .navigationTitle("成員")
        .task { await reload() }
        .sheet(isPresented: $confirmingLeave) {
            NavigationStack {
                List {
                    Section {
                        Text("退出後無法同步修改這趟旅程。共同內容與已完成紀錄會保留，以下未完成分工回待認領。")
                    }
                    if let departure {
                        Section("需要旅伴重新認領") {
                            if departure.items.isEmpty { Text("目前沒有分配給你的未完成共同物品。") }
                            ForEach(departure.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                    Text("\(item.kind == "packing" ? "用品" : "待買")・\(item.quantity) 份・\(item.carrying == true ? (item.buying ? "攜帶及採買" : "攜帶") : "採買")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section {
                            Text("私人用品不會轉為共同物品；退出後無法從這趟旅程存取。")
                            Button(leaving ? "退出中…" : "確認退出", role: .destructive) { Task { await leave() } }
                                .disabled(leaving)
                        }
                    }
                    if let errorMessage { ErrorText(errorMessage) }
                }
                .navigationTitle("退出前確認")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { confirmingLeave = false }.disabled(leaving) } }
                .interactiveDismissDisabled(leaving)
            }
        }
        .confirmationDialog("邀請這位旅伴接任擁有者？對方接受後，你會改為可編輯旅伴。", isPresented: Binding(get: { ownershipTarget != nil }, set: { if !$0 { ownershipTarget = nil } }), titleVisibility: .visible) {
            if let target = ownershipTarget { Button("邀請 \(target.displayName) 接任") { Task { await transfer(to: target.userID) } } }
        }
    }

    private func transfer(to userID: UUID?) async {
        do { try await session.trips.offerOwnership(tripID: trip.id, to: userID); await reload() }
        catch { errorMessage = userMessage(for: error) }
    }
    private func respond(_ offer: OwnershipOffer, accept: Bool) async {
        do { try await session.trips.respondOwnership(tripID: trip.id, from: offer.from_user, accept: accept); await reload() }
        catch { errorMessage = userMessage(for: error) }
    }
    private func prepareDeparture() async {
        loadingDeparture = true
        errorMessage = nil
        defer { loadingDeparture = false }
        do { departure = try await session.trips.previewDeparture(tripID: trip.id); confirmingLeave = true }
        catch { errorMessage = userMessage(for: error) }
    }
    private func leave() async {
        guard let departure else { return }
        leaving = true
        defer { leaving = false }
        do {
            try await session.trips.leaveTrip(tripID: trip.id, expectedRevision: departure.revision)
            confirmingLeave = false
            dismiss()
        } catch BackendError.conflict("STALE_REVISION") {
            self.departure = nil
            do {
                self.departure = try await session.trips.previewDeparture(tripID: trip.id)
                errorMessage = "旅伴剛剛修改了資料，已更新影響清單，請重新確認。"
            } catch { errorMessage = userMessage(for: error) }
        } catch { errorMessage = userMessage(for: error) }
    }
    private func reload() async {
        do {
            members = try await session.trips.members(of: trip.id)
            currentRole = try await session.trips.myRole(in: trip.id)
            offer = try await session.trips.ownershipOffer(tripID: trip.id)
        } catch {
            errorMessage = "讀取失敗：\(userMessage(for: error))"
        }
    }

    private func invite() async {
        do {
            let token = try await session.trips.createInvite(tripID: trip.id, role: inviteRole)
            if let backend = BackendConfig.fromBundle()?.url { inviteURL = InviteLink.webURL(token: token, backend: backend) }
            appURL = InviteLink.appURL(token: token)
        } catch {
            errorMessage = "無法建立邀請：\(userMessage(for: error))"
        }
    }

    private func setRole(_ member: TripMember, _ role: TripRole) async {
        do { try await session.trips.setMemberRole(tripID: trip.id, userID: member.userID, role: role); await reload() }
        catch { errorMessage = "更新失敗：\(userMessage(for: error))" }
    }

    private func remove(_ member: TripMember) async {
        do { try await session.trips.removeMember(tripID: trip.id, userID: member.userID); await reload() }
        catch { errorMessage = "移除失敗：\(userMessage(for: error))" }
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
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && InviteLink.token(from: text) == nil {
                        Text("這不是邀請連結。請貼上好友傳來、以 beartravel://invite 開頭的完整連結。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("加入後可依權限查看或編輯共同的收藏、購物清單與行程。")
                }
                Button(joining ? "加入中…" : "加入") { Task { await join() } }
                    .disabled(joining || InviteLink.token(from: text) == nil)
            if let errorMessage { ErrorText(errorMessage) }
            }
            .scrollDismissesKeyboard(.interactively)
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
            default: "加入失敗：\(error.userMessage)"
            }
        } catch {
            errorMessage = "加入失敗：\(userMessage(for: error))"
        }
    }
}
