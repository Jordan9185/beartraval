import AppCore
import ShareCore
import SwiftUI

struct PackingView: View {
    let session: SessionModel
    let trip: Trip
    let canEdit: Bool
    @State private var items: [PackingItem] = []
    @State private var shared = false
    @State private var editing: PackingItem?
    @State private var errorMessage: String?
    @State private var loading = true
    @State private var suggestions: [AssistantAnswer.PackingSuggestion] = []
    @State private var asking = false
    @State private var pendingCount = 0
    @State private var confirmDiscard = false

    var body: some View {
        List {
            Section {
                Picker("用品範圍", selection: $shared) {
                    Text("我的物品").tag(false)
                    Text("共同物品").tag(true)
                }.pickerStyle(.segmented)
                Text("已購買與已裝好分開記錄；勾選表示所需數量都已裝好。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if canEdit {
                Section("AI 用品建議") {
                    Button(asking ? "AI 正在整理…" : "依這趟旅程建議用品") { Task { await suggest() } }.disabled(asking)
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                        VStack(alignment: .leading) {
                            Text("\(suggestion.name) × \(suggestion.quantity)")
                            Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                            Button("選用並核對") {
                                if let owner = session.trips.currentUserID {
                                    var item = PackingItem(tripID: trip.id, ownerID: owner, shared: shared)
                                    item.name = suggestion.name; item.quantity = suggestion.quantity; item.note = suggestion.reason
                                    editing = item
                                }
                            }
                            Button("略過這項") {
                                if let owner = session.trips.currentUserID {
                                    PackingSuggestions.skip(suggestion.name, trip: trip.id, owner: owner, shared: shared)
                                }
                                suggestions.remove(at: index)
                            }.font(.caption)
                        }
                    }
                }
            }
            if pendingCount > 0 {
                Text("\(pendingCount) 項用品修改保存在此裝置，待同步。") .foregroundStyle(.orange)
                Button("重試同步") { Task { await load() } }
                Button("放棄待送修改，重新載入", role: .destructive) { confirmDiscard = true }
            }
            if loading { ProgressView("讀取用品…") }
            if let errorMessage { ErrorText(errorMessage) }
            ForEach(items.filter { $0.shared == shared }) { item in
                PackingRow(item: item, canEdit: canEdit, edit: { editing = item }) {
                    var updated = item
                    updated.packed.toggle()
                    Task { await save(updated) }
                }
            }
            if !loading && items.filter({ $0.shared == shared }).isEmpty {
                Text("還沒有用品，可以手動新增。") .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("旅行必備用品")
        .toolbar {
            if canEdit {
                Button("新增用品", systemImage: "plus") {
                    if let owner = session.trips.currentUserID {
                        editing = PackingItem(tripID: trip.id, ownerID: owner, shared: shared)
                    }
                }
            }
        }
        .sheet(item: $editing) { item in
            PackingEditView(session: session, original: item) { Task { await load() } }
        }
        .task { await load(); await readSuggestions() }
        .onChange(of: session.aiActivity.completionVersion) { Task { await readSuggestions() } }
        .onChange(of: shared) { Task { await readSuggestions() } }
        .refreshable { await load() }
        .confirmationDialog("放棄這趟用品尚未同步的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放棄待送修改", role: .destructive) {
                Task {
                    guard let owner = session.trips.currentUserID else { return }
                    do { try await PackingJournal.shared.discard(tripID: trip.id, owner: owner); await load() }
                    catch { errorMessage = userMessage(for: error) }
                }
            }
        }
    }

    private var excludedNames: Set<String> {
        let existing = Set(items.filter { $0.shared == shared }.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard let owner = session.trips.currentUserID else { return existing }
        return existing.union(PackingSuggestions.skipped(trip: trip.id, owner: owner, shared: shared))
    }
    private func readSuggestions() async {
        do { suggestions = try await session.trips.latestPackingSuggestions(tripID: trip.id).filter { !excludedNames.contains($0.name.lowercased()) } }
        catch { /* 既有用品仍可離線使用，AI 建議另行重試。 */ }
    }
    private func suggest() async {
        asking = true
        defer { asking = false }
        do {
            let result = try await session.trips.ask(tripID: trip.id,
                question: PackingSuggestions.question,
                today: nil, routeFacts: [])
            switch result {
            case .answered(let answer):
                let names = excludedNames
                suggestions = (answer.packingSuggestions ?? []).filter { !names.contains($0.name.lowercased()) }
                if suggestions.isEmpty { errorMessage = answer.answer }
            case .failed(let reason): errorMessage = PersonalAI.waitingMessage(reason) ?? "AI 暫時無法提供用品建議。"
            }
        } catch { errorMessage = userMessage(for: error) }
    }

    private func load() async {
        defer { loading = false }
        guard let owner = session.trips.currentUserID else { return }
        errorMessage = await PackingJournal.shared.flush(repository: session.trips, owner: owner)
        do {
            let fresh = try await session.trips.packingItems(tripID: trip.id)
            try await PackingJournal.shared.cache(fresh, tripID: trip.id, owner: owner)
        } catch { errorMessage = "顯示此裝置保存的用品；\(userMessage(for: error))" }
        items = await PackingJournal.shared.items(tripID: trip.id, owner: owner)
        pendingCount = await PackingJournal.shared.pendingCount(tripID: trip.id, owner: owner)
    }

    private func save(_ item: PackingItem) async {
        guard let owner = session.trips.currentUserID else { return }
        do { try await PackingJournal.shared.enqueue(item, deleted: false, owner: owner); await load() }
        catch { errorMessage = "未保存在此裝置：\(userMessage(for: error))" }
    }

}

private struct PackingRow: View {
    let item: PackingItem
    let canEdit: Bool
    let edit: () -> Void
    let toggle: () -> Void
    var body: some View {
        HStack {
            Button(action: toggle) {
                Image(systemName: item.packed ? "checkmark.circle.fill" : "circle")
            }.buttonStyle(.borderless).disabled(!canEdit).accessibilityLabel(item.packed ? "取消已裝好" : "標記已裝好")
            Button(action: edit) {
                VStack(alignment: .leading) {
                    Text("\(item.name) × \(item.quantity)")
                    if !item.note.isEmpty { Text(item.note).font(.caption).foregroundStyle(.secondary) }
                    Text(item.packed ? "已裝好" : "未裝好").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain).disabled(!canEdit)
        }
    }
}

private struct PackingEditView: View {
    let session: SessionModel
    let original: PackingItem
    let onSaved: () -> Void
    @State private var item: PackingItem
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var deleting = false
    @State private var purchaseImpact = false
    @State private var members: [TripMember] = []
    @Environment(\.dismiss) private var dismiss

    init(session: SessionModel, original: PackingItem, onSaved: @escaping () -> Void) {
        self.session = session; self.original = original; self.onSaved = onSaved
        _item = State(initialValue: original)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("用品名稱", text: $item.name)
                Stepper("數量：\(item.quantity)", value: $item.quantity, in: 1...999)
                TextField("備註", text: $item.note, axis: .vertical)
                if item.revision == 0 { Toggle("共同物品（旅伴可見）", isOn: $item.shared) }
                if item.shared {
                    Picker("誰負責帶", selection: $item.carrier_id) {
                        Text("尚未分工").tag(Optional<UUID>.none)
                        ForEach(members) { Text($0.displayName).tag(Optional($0.userID)) }
                    }
                    Picker("誰負責買", selection: $item.buyer_id) {
                        Text("尚未分工").tag(Optional<UUID>.none)
                        ForEach(members) { Text($0.displayName).tag(Optional($0.userID)) }
                    }
                }
                if item.needsRepacking(comparedTo: original) && original.packed {
                    Text("名稱、數量或攜帶人改變，儲存後會回到未裝好。") .foregroundStyle(.orange)
                }
                if let errorMessage { ErrorText(errorMessage) }
                if item.revision > 0 {
                    if let timing = original.purchase_timing {
                        Text(timing == "before_trip" ? "已加入出發前購買清單" : "已加入旅途中購買清單")
                    } else {
                        Menu("需要購買") {
                            Button("出發前買好") { Task { await requestPurchase(beforeTrip: true) } }
                            Button("旅途中購買") { Task { await requestPurchase(beforeTrip: false) } }
                        }
                        Text(item.shared ? "加入共同購物；買齊不會自動勾選已裝好。" : "加入我的私人購物，不公開給旅伴。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("刪除用品", role: .destructive) { deleting = true }
                }
            }
            .task {
                do { members = try await session.trips.members(of: item.trip_id) }
                catch { errorMessage = userMessage(for: error) }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(item.revision == 0 ? "新增用品" : "編輯用品")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "儲存中…" : "儲存") {
                        if original.purchase_timing != nil && (item.name != original.name || item.quantity != original.quantity) {
                            purchaseImpact = true
                        } else { Task { await save() } }
                    }
                        .disabled(saving || item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.name.count > 120 || item.note.count > 2000)
                }
            }
            .confirmationDialog("核對已連結的採買", isPresented: $purchaseImpact, titleVisibility: .visible) {
                Button("確認只修改用品") { Task { await save() } }
                Button("返回修改", role: .cancel) { }
            } message: {
                Text("用品將由「\(original.name) × \(original.quantity)」改為「\(item.name) × \(item.quantity)」。採買清單及已購買紀錄維持原值，需要時請另到採買清單調整。名稱更正或增加份數會重新核對打包。")
            }
            .confirmationDialog("只刪除用品，不更動購物或行程。", isPresented: $deleting, titleVisibility: .visible) {
                Button("刪除用品", role: .destructive) { Task { await save(deleted: true) } }
            }
        }
    }

    private func requestPurchase(beforeTrip: Bool) async {
        do {
            // 未儲存的更正不能靜默套用到購物，使用目前已保存版本。
            guard item == original else { errorMessage = "請先儲存用品修改，再加入購物清單。"; return }
            try await session.trips.requestPackingPurchase(original, beforeTrip: beforeTrip)
            onSaved(); dismiss()
        } catch { errorMessage = "尚未加入購物：\(userMessage(for: error))" }
    }

    private func save(deleted: Bool = false) async {
        saving = true
        defer { saving = false }
        do {
            guard let owner = session.trips.currentUserID else { return }
            if item.needsRepacking(comparedTo: original) { item.packed = false }
            try await PackingJournal.shared.enqueue(item, deleted: deleted, owner: owner)
            onSaved(); dismiss()
        }
        catch { errorMessage = "未儲存：\(userMessage(for: error))。你的輸入仍保留。" }
    }
}

/// 旅程與 Today 共用的準備摘要；只讀資料，不觸發 AI 或自動送出修改。
struct TripPreparationSummary: View {
    let session: SessionModel
    let tripID: UUID
    let revision: Int
    @State private var items: [PackingItem]?
    @State private var pending = 0
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let items {
                let personal = items.filter { !$0.shared }
                let shared = items.filter(\.shared)
                Text("我的用品：已裝好 \(personal.filter(\.packed).count)／\(personal.count) 項")
                Text("共同用品：已裝好 \(shared.filter(\.packed).count)／\(shared.count) 項")
                if items.isEmpty { Text("還沒有用品，進入清單可新增或選用 AI 建議。") }
                if pending > 0 { Text("含 \(pending) 項此裝置待同步修改").foregroundStyle(.orange) }
            } else if errorMessage == nil { ProgressView("讀取準備進度…") }
            if let errorMessage { Text(errorMessage) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .task(id: "\(tripID)-\(revision)") { await load() }
    }

    private func load() async {
        items = nil
        pending = 0
        errorMessage = nil
        guard let owner = session.trips.currentUserID else { errorMessage = "登入後查看準備進度。"; return }
        do {
            let latest = try await session.trips.packingItems(tripID: tripID)
            guard !Task.isCancelled, session.trips.currentUserID == owner else { return }
            try await PackingJournal.shared.cache(latest, tripID: tripID, owner: owner)
            let visible = await PackingJournal.shared.items(tripID: tripID, owner: owner)
            let waiting = await PackingJournal.shared.pendingCount(tripID: tripID, owner: owner)
            guard !Task.isCancelled, session.trips.currentUserID == owner else { return }
            items = visible
            pending = waiting
        } catch {
            guard !Task.isCancelled, session.trips.currentUserID == owner else { return }
            // 未取得資料不能把未知顯示成零項／全部完成。
            errorMessage = "準備進度暫時無法更新，可進用品清單查看此裝置已保存的內容。"
        }
    }
}
