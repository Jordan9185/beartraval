import Foundation

/// 購買數量的帳號隔離待送資料。版本衝突保留使用者輸入，絕不默默覆寫旅伴修改。
public actor PurchaseJournal {
    public static let shared = PurchaseJournal()
    public struct SharedDraft: Codable, Sendable {
        public var item: ShoppingItem
        public var desired: Int
        public var bought: Int
        public var buyer: UUID?
        public var demands: [ShoppingDemand]
        public var members: [TripMember]
        public init(item: ShoppingItem, desired: Int, bought: Int, buyer: UUID?, demands: [ShoppingDemand], members: [TripMember]) {
            self.item = item; self.desired = desired; self.bought = bought; self.buyer = buyer; self.demands = demands; self.members = members
        }
    }
    private enum Edit: Codable { case shared(SharedDraft), personal(PersonalPurchase)
        var id: UUID { switch self { case .shared(let d): d.item.id; case .personal(let d): d.id } }
    }
    private struct Pending: Codable { var operationID: UUID; var edit: Edit }
    private struct State: Codable {
        var shopping: [UUID: [ShoppingEntry]]?
        var shared: [UUID: SharedDraft] = [:]
        var personal: [PersonalPurchase] = []
        var pending: [Pending] = []
    }
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }
    private var states: [UUID: State] = [:]
    private var flushing: Set<UUID> = []
    private func file(_ owner: UUID) throws -> URL {
        guard let root = directory ?? AppGroup.containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "BeaRTravelPreparation", directoryHint: .isDirectory) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appending(path: "purchases-\(owner.uuidString).json")
    }
    private func state(_ owner: UUID) -> State {
        if let cached = states[owner] { return cached }
        let cached = (try? file(owner)).flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        states[owner] = cached; return cached
    }
    private func write(_ state: State, owner: UUID) throws {
        try JSONEncoder().encode(state).write(to: file(owner), options: .atomic)
        states[owner] = state
    }
    public func cache(_ draft: SharedDraft, owner: UUID) throws {
        var value = state(owner); value.shared[draft.item.id] = draft; try write(value, owner: owner)
    }
    public func cache(_ items: [PersonalPurchase], owner: UUID) throws {
        var value = state(owner); value.personal = items; try write(value, owner: owner)
    }
    public func cache(entries: [ShoppingEntry], tripID: UUID, owner: UUID) throws {
        var value = state(owner)
        if value.shopping == nil { value.shopping = [:] }
        value.shopping?[tripID] = entries
        try write(value, owner: owner)
    }
    /// 只疊上同一帳號的待送數量，保留伺服器站點與版本；不捏造購買事件。
    public func shoppingEntries(tripID: UUID, owner: UUID) -> [ShoppingEntry] {
        let value = state(owner)
        return (value.shopping?[tripID] ?? []).map { entry in
            var next = entry
            if let pending = value.pending.first(where: { $0.edit.id == entry.id }),
               case .shared(let draft) = pending.edit, draft.item.tripId == tripID {
                next.item.desiredQuantity = draft.desired
                next.item.boughtQuantity = draft.bought
                next.item.buyerID = draft.buyer
            }
            return next
        }
    }
    public func pendingShoppingIDs(tripID: UUID, owner: UUID) -> Set<UUID> {
        Set(state(owner).pending.compactMap { pending in
            if case .shared(let draft) = pending.edit, draft.item.tripId == tripID { return draft.item.id }
            return nil
        })
    }
    public func sharedDraft(id: UUID, owner: UUID) -> SharedDraft? {
        let value = state(owner)
        if let pending = value.pending.first(where: { $0.edit.id == id }), case .shared(let draft) = pending.edit { return draft }
        return value.shared[id]
    }
    public func personalItems(owner: UUID) -> [PersonalPurchase] {
        let value = state(owner); var items = value.personal
        for pending in value.pending { if case .personal(let item) = pending.edit { items.removeAll { $0.id == item.id }; items.append(item) } }
        return items
    }
    public func hasPending(id: UUID, owner: UUID) -> Bool { state(owner).pending.contains { $0.edit.id == id } }
    public func enqueue(_ draft: SharedDraft, owner: UUID) throws { try enqueue(.shared(draft), owner: owner) }
    public func enqueue(_ item: PersonalPurchase, owner: UUID) throws { try enqueue(.personal(item), owner: owner) }
    private func enqueue(_ edit: Edit, owner: UUID) throws {
        var value = state(owner)
        // 使用者先核對前一次送出結果，才能修改同一筆；不替換已在途的請求。
        guard !value.pending.contains(where: { $0.edit.id == edit.id }) else { throw BackendError.staleRevision }
        value.pending.append(Pending(operationID: UUID(), edit: edit)); try write(value, owner: owner)
    }
    public func discard(id: UUID, owner: UUID) throws {
        var value = state(owner); value.pending.removeAll { $0.edit.id == id }; try write(value, owner: owner)
    }
    public func flush(repository: TripRepository, owner: UUID) async -> String? {
        guard !flushing.contains(owner) else { return nil }
        flushing.insert(owner); defer { flushing.remove(owner) }
        for pending in state(owner).pending {
            do {
                switch pending.edit {
                case .shared(let draft):
                    try await repository.setShoppingQuantities(item: draft.item, desired: draft.desired, bought: draft.bought,
                        buyerID: draft.buyer, demands: draft.demands, operationID: pending.operationID)
                case .personal(let item): try await repository.setPersonalPurchase(item, operationID: pending.operationID)
                }
                var value = state(owner)
                switch pending.edit {
                case .shared(var draft):
                    draft.item.quantityRevision = (draft.item.quantityRevision ?? 0) + 1
                    draft.item.desiredQuantity = draft.desired; draft.item.boughtQuantity = draft.bought; draft.item.buyerID = draft.buyer
                    value.shared[draft.item.id] = draft
                case .personal(var item):
                    item.revision += 1; value.personal.removeAll { $0.id == item.id }; value.personal.append(item)
                }
                value.pending.removeAll { $0.operationID == pending.operationID }; try write(value, owner: owner)
            } catch BackendError.staleRevision { return "購買資料已被修改；你的待送數量仍保留，請核對後再決定。" }
            catch { return "購買修改已保存在此裝置，尚未同步：\((error as? BackendError)?.userMessage ?? "請確認連線")" }
        }
        return nil
    }
}
