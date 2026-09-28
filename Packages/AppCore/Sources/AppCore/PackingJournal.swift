import Foundation

/// 帳號隔離的用品快取與待送修改；衝突不丟棄原意圖，不自動用新版覆蓋。
public actor PackingJournal {
    public static let shared = PackingJournal()
    public struct Pending: Codable, Sendable {
        public var operationID: UUID
        public var item: PackingItem
        public var deleted: Bool
    }
    private struct State: Codable {
        var cache: [UUID: [PackingItem]] = [:]
        var pending: [Pending] = []
    }
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }
    private var states: [UUID: State] = [:]

    private func file(_ owner: UUID) -> URL? {
        let directory = self.directory ?? AppGroup.containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "BeaRTravelPreparation", directoryHint: .isDirectory)
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "packing-\(owner.uuidString).json")
    }
    private func state(_ owner: UUID) -> State {
        if let known = states[owner] { return known }
        let value = file(owner).flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        states[owner] = value
        return value
    }
    private func write(_ value: State, owner: UUID) throws {
        guard let file = file(owner) else { throw CocoaError(.fileWriteUnknown) }
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        states[owner] = value
    }
    public func cache(_ items: [PackingItem], tripID: UUID, owner: UUID) throws {
        var value = state(owner); value.cache[tripID] = items
        try write(value, owner: owner)
    }
    public func items(tripID: UUID, owner: UUID) -> [PackingItem] {
        let value = state(owner)
        var items = value.cache[tripID] ?? []
        for pending in value.pending where pending.item.trip_id == tripID {
            items.removeAll { $0.id == pending.item.id }
            if !pending.deleted { items.append(pending.item) }
        }
        return items
    }
    public func pendingCount(tripID: UUID, owner: UUID) -> Int { state(owner).pending.filter { $0.item.trip_id == tripID }.count }
    public func enqueue(_ item: PackingItem, deleted: Bool, owner: UUID) throws {
        var value = state(owner)
        // 同一項未送出的後續更正沿用原 revision；失敗／衝突後仍保留完整輸入。
        if let index = value.pending.firstIndex(where: { $0.item.id == item.id }) {
            var updated = item; updated.revision = value.pending[index].item.revision
            value.pending[index] = Pending(operationID: UUID(), item: updated, deleted: deleted)
        } else { value.pending.append(Pending(operationID: UUID(), item: item, deleted: deleted)) }
        try write(value, owner: owner)
    }
    public func discard(tripID: UUID, owner: UUID) throws {
        var value = state(owner); value.pending.removeAll { $0.item.trip_id == tripID }
        try write(value, owner: owner)
    }
    private var flushing = Set<UUID>()
    public func flush(repository: TripRepository, owner: UUID) async -> String? {
        guard !flushing.contains(owner) else { return nil }
        flushing.insert(owner)
        defer { flushing.remove(owner) }
        for pending in state(owner).pending {
            do {
                let saved = try await repository.savePackingItem(pending.item, deleted: pending.deleted, operationID: pending.operationID)
                var value = state(owner)
                value.pending.removeAll { $0.operationID == pending.operationID }
                var cached = value.cache[saved.trip_id] ?? []
                cached.removeAll { $0.id == saved.id }
                if !pending.deleted { cached.append(saved) }
                value.cache[saved.trip_id] = cached
                try write(value, owner: owner)
            } catch BackendError.staleRevision {
                return "用品已被修改，待送的內容仍保留。請核對新版後再整理，或放棄這批待送修改。"
            } catch { return "用品修改保留在此裝置，尚未同步：\((error as? BackendError)?.userMessage ?? "連線或權限需確認")" }
        }
        return nil
    }
}
