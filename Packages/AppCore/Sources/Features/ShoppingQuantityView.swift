import AppCore
import ShareCore
import SwiftUI

struct ShoppingQuantityView: View {
    let repository: TripRepository
    let entry: ShoppingEntry
    let onSaved: () -> Void
    @State private var scheduledDay: TripDay?
    @State private var confirmUnschedule = false
    @State private var desired = 1
    @State private var bought = 0
    @State private var buyer: UUID?
    @State private var members: [TripMember] = []
    @State private var demands: [UUID: Int] = [:]
    @State private var split = false
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var baseItem: ShoppingItem?
    @State private var pending = false
    @State private var discardPending = false
    @Environment(\.dismiss) private var dismiss

    private var total: Int { split ? demands.values.reduce(0, +) : desired }
    var body: some View {
        Form {
            Section(entry.item.name) {
                Toggle("分人記錄需要數量", isOn: $split)
                if split {
                    ForEach(members) { member in
                        Stepper("\(member.displayName)：\(demands[member.userID] ?? 0)", value: Binding(
                            get: { demands[member.userID] ?? 0 }, set: { demands[member.userID] = $0 }), in: 0...999)
                    }
                    ForEach(demands.keys.filter { id in !members.contains { $0.userID == id } }.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                        Stepper("已退出旅伴原需求：\(demands[id] ?? 0)", value: Binding(get: { demands[id] ?? 0 }, set: { demands[id] = $0 }), in: 0...999)
                        Text("原需求保留；請核對後設為 0，或重新分配給目前旅伴，才能儲存。") .font(.caption).foregroundStyle(.secondary)
                    }
                } else { Stepper("需要：\(desired)", value: $desired, in: 1...999) }
                Stepper("已買：\(bought)", value: $bought, in: 0...999)
                Text("已買 \(bought)／需要 \(total)；\(bought >= total && total > 0 ? "已買齊" : "尚未買齊")")
                Picker("誰負責買", selection: $buyer) {
                    Text("尚未分工").tag(Optional<UUID>.none)
                    ForEach(members) { Text($0.displayName).tag(Optional($0.userID)) }
                }
                if let buyer, !members.contains(where: { $0.userID == buyer }) {
                    Text("原採買人已退出；儲存修改前，請明確選擇目前旅伴或尚未分工。") .font(.caption).foregroundStyle(.orange)
                }
                Text("分人需求與誰負責買分開。已買數量不自動分配給任何人，也不自動勾選已裝好。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(pending || saving || !loaded)
            // 主要動作緊接在數量後，不放在撤回安排（破壞性）下方。
            Section {
                if let errorMessage { ErrorText(errorMessage) }
                Button(saving ? "儲存中…" : "儲存數量與分工") { Task { await save() } }
                    .disabled(!loaded || pending || saving || total < 1 || total > 999)
            }
            if pending {
                Section("此裝置有待送修改") {
                    Text("你的數量保留在這裡，尚未確認同步。先重試，或核對後放棄待送內容。")
                    Button("重試同步") { Task { await retry() } }.disabled(saving)
                    Button("放棄待送，讀取最新資料", role: .destructive) { discardPending = true }.disabled(saving)
                }
            }
            if entry.item.plannedStopId != nil {
                Section { Button("撤回這件商品的行程安排", role: .destructive) { confirmUnschedule = true }.disabled(scheduledDay == nil || saving) }
                footer: { Text("商品與購買記錄保留。其他商品仍使用的採買站、固定站及收藏共用站都不刪除。") }
            }
        }
        .navigationTitle("購買數量與分工")
        .confirmationDialog("撤回商品安排？未儲存的數量修改不會一併儲存。", isPresented: $confirmUnschedule, titleVisibility: .visible) {
            Button("只撤回商品，保留站點") { Task { await unschedule(removeEmpty: false) } }
            Button("撤回並移除無其他用途的採買站", role: .destructive) { Task { await unschedule(removeEmpty: true) } }
        }
        .confirmationDialog("放棄這件商品尚未同步的數量修改？", isPresented: $discardPending, titleVisibility: .visible) {
            Button("放棄並重新載入", role: .destructive) { Task {
                guard let owner = repository.currentUserID else { return }
                do { try await PurchaseJournal.shared.discard(id: entry.id, owner: owner); await load() }
                catch { errorMessage = userMessage(for: error) }
            } }
        }
        .task { await load() }
    }
    private func load() async {
        guard let owner = repository.currentUserID else { return }
        do {
            guard let latest = try await repository.shoppingEntries(of: entry.item.tripId).first(where: { $0.id == entry.id }) else { throw BackendError.notFound }
            let people = try await repository.members(of: entry.item.tripId)
            let split = try await repository.shoppingDemands(itemID: entry.id)
            try await PurchaseJournal.shared.cache(.init(item: latest.item, desired: latest.item.desiredQuantity ?? 1,
                bought: latest.item.boughtQuantity ?? (latest.isPurchased ? 1 : 0), buyer: latest.item.buyerID,
                demands: split, members: people), owner: owner)
            if let stopID = latest.item.plannedStopId, let stop = try await repository.stops(of: entry.item.tripId).first(where: { $0.id == stopID }) {
                scheduledDay = try await repository.days(of: entry.item.tripId).first { $0.id == stop.dayId }
            }
        } catch { errorMessage = "使用此裝置保存的數量與分工：\(userMessage(for: error))" }
        if let draft = await PurchaseJournal.shared.sharedDraft(id: entry.id, owner: owner) {
            baseItem = draft.item; desired = draft.desired; bought = draft.bought; buyer = draft.buyer
            members = draft.members; demands = Dictionary(uniqueKeysWithValues: draft.demands.map { ($0.user_id, $0.quantity) })
            split = !draft.demands.isEmpty; loaded = true
        }
        pending = await PurchaseJournal.shared.hasPending(id: entry.id, owner: owner)
    }
    private func retry() async {
        guard let owner = repository.currentUserID else { return }
        saving = true
        defer { saving = false }
        errorMessage = await PurchaseJournal.shared.flush(repository: repository, owner: owner)
        await load(); onSaved()
    }

    private func unschedule(removeEmpty: Bool) async {
        guard let stopID = entry.item.plannedStopId, let day = scheduledDay else { return }
        saving = true
        defer { saving = false }
        do { try await repository.unschedulePurchase(itemID: entry.id, stopID: stopID, revision: day.routeRevision, removeEmpty: removeEmpty); onSaved(); dismiss() }
        catch { errorMessage = "撤回未完成：\(userMessage(for: error))。請重新核對行程。" }
    }
    private func save() async {
        saving = true
        defer { saving = false }
        guard let owner = repository.currentUserID, let baseItem else { return }
        do {
            try await PurchaseJournal.shared.enqueue(.init(item: baseItem, desired: total, bought: bought, buyer: buyer,
                demands: split ? demands.filter { $0.value > 0 }.map { ShoppingDemand(userID: $0.key, quantity: $0.value) } : [], members: members), owner: owner)
            await retry()
            if !pending { dismiss() }
        } catch { errorMessage = "尚未保存：\(userMessage(for: error))。輸入仍保留。" }
    }
}
