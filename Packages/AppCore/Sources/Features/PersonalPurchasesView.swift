import AppCore
import ShareCore
import SwiftUI

struct PersonalPurchasesView: View {
    let repository: TripRepository
    @State private var items: [PersonalPurchase] = []
    @State private var errorMessage: String?
    @State private var loading = true
    var body: some View {
        List {
            Text("這些用品採買只有你看得到；已購買不等於已裝好。") .font(.caption).foregroundStyle(.secondary)
            if loading { ProgressView("讀取用品採買…") }
            if let errorMessage { ErrorText(errorMessage) }
            if !loading && items.isEmpty { Text("還沒有用品採買，從旅行必備用品選擇需要購買即可加入。") }
            ForEach(items) { item in
                NavigationLink(item.name + " · 已買 \(item.bought_quantity)／\(item.desired_quantity)") {
                    PersonalPurchaseEdit(repository: repository, original: item) { Task { await load() } }
                }
            }
        }
        .navigationTitle("我的用品採買")
        .task { await load() }
        .refreshable { await load() }
    }
    private func load() async {
        defer { loading = false }
        guard let owner = repository.currentUserID else { return }
        errorMessage = await PurchaseJournal.shared.flush(repository: repository, owner: owner)
        do { try await PurchaseJournal.shared.cache(repository.personalPurchases(), owner: owner) }
        catch { errorMessage = "顯示此裝置保存的用品採買：\(userMessage(for: error))" }
        items = await PurchaseJournal.shared.personalItems(owner: owner)
    }
}
private struct PersonalPurchaseEdit: View {
    let repository: TripRepository
    let onSaved: () -> Void
    @State private var item: PersonalPurchase
    @State private var errorMessage: String?
    @State private var pending = false
    @State private var saving = false
    @State private var confirmDiscard = false
    @Environment(\.dismiss) private var dismiss
    init(repository: TripRepository, original: PersonalPurchase, onSaved: @escaping () -> Void) {
        self.repository = repository; self.onSaved = onSaved; _item = State(initialValue: original)
    }
    var body: some View {
        Form {
            Section {
                Text(item.name)
                Text(item.purchase_timing == "before_trip" ? "出發前買好" : "旅途中購買")
                Stepper("需要：\(item.desired_quantity)", value: $item.desired_quantity, in: 1...999)
                Stepper("已買：\(item.bought_quantity)", value: $item.bought_quantity, in: 0...999)
            }.disabled(pending || saving)
            if let errorMessage { ErrorText(errorMessage) }
            if pending {
                Text("這筆修改已保存在此裝置，尚未確認同步。")
                Button("重試同步") { Task { await retry() } }.disabled(saving)
                Button("放棄待送修改", role: .destructive) { confirmDiscard = true }.disabled(saving)
            } else { Button("儲存") { Task { await save() } }.disabled(saving) }
        }.navigationTitle("用品購買進度")
        .task { if let owner = repository.currentUserID { pending = await PurchaseJournal.shared.hasPending(id: item.id, owner: owner) } }
        .confirmationDialog("放棄這件用品尚未同步的購買數量？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放棄並返回清單", role: .destructive) { Task {
                guard let owner = repository.currentUserID else { return }
                do { try await PurchaseJournal.shared.discard(id: item.id, owner: owner); onSaved(); dismiss() }
                catch { errorMessage = userMessage(for: error) }
            } }
        }
    }
    private func retry() async {
        guard let owner = repository.currentUserID else { return }
        saving = true; defer { saving = false }
        errorMessage = await PurchaseJournal.shared.flush(repository: repository, owner: owner)
        pending = await PurchaseJournal.shared.hasPending(id: item.id, owner: owner)
        onSaved()
        if !pending { dismiss() }
    }
    private func save() async {
        guard let owner = repository.currentUserID else { return }
        do { try await PurchaseJournal.shared.enqueue(item, owner: owner); await retry() }
        catch { errorMessage = "未保存：\(userMessage(for: error))" }
    }
}
