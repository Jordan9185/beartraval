import Foundation

/// 離線時可先排隊的操作（決策 D6：Saved／Shopping／購買可離線，行程修改需在線）。
public enum QueuedOperation: Codable, Equatable, Sendable {
    case savePlace(tripID: UUID, label: String, category: SavedCategory, placeID: UUID?, source: SavedSource?)
    case setInterest(savedID: UUID, interested: Bool)
    case recordPurchase(itemID: UUID, purchased: Bool)
}

public struct QueuedItem: Codable, Identifiable, Equatable, Sendable {
    /// 同時作為伺服器端的冪等鍵：重送不會產生重複資料。
    public var id: UUID
    public var createdAt: Date
    public var operation: QueuedOperation
    public var attempts: Int

    public init(id: UUID = UUID(), createdAt: Date = Date(), operation: QueuedOperation, attempts: Int = 0) {
        self.id = id
        self.createdAt = createdAt
        self.operation = operation
        self.attempts = attempts
    }
}

public protocol QueuedOperationExecutor: Sendable {
    func execute(_ item: QueuedItem) async throws
}

/// 依序送出；遇到網路錯誤就停（保留後面的順序），伺服器拒絕的操作丟棄並回報。
public actor OfflineQueue {
    public private(set) var items: [QueuedItem]
    private let file: URL?

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([QueuedItem].self, from: data) {
            items = saved
        } else {
            items = []
        }
    }

    /// App Group 內的共用佇列（App 與 Extension 都能加入）。
    public static func shared() -> OfflineQueue {
        OfflineQueue(file: AppGroup.containerURL?.appending(path: "offline-queue.json"))
    }

    public func enqueue(_ operation: QueuedOperation) {
        items.append(QueuedItem(operation: operation))
        persist()
    }

    public struct FlushResult: Equatable, Sendable {
        public var sent = 0
        public var rejected: [QueuedItem] = []
        public var remaining = 0
    }

    public func flush(using executor: any QueuedOperationExecutor) async -> FlushResult {
        var result = FlushResult()
        while let item = items.first {
            do {
                try await executor.execute(item)
                result.sent += 1
                items.removeFirst()
            } catch let error as BackendError where !Self.isTransient(error) {
                result.rejected.append(item)
                items.removeFirst()
            } catch {
                items[0].attempts += 1
                break
            }
            persist()
        }
        persist()
        result.remaining = items.count
        return result
    }

    static func isTransient(_ error: BackendError) -> Bool {
        if case .other = error { return true }
        return false
    }

    private func persist() {
        guard let file else { return }
        try? JSONEncoder().encode(items).write(to: file, options: .atomic)
    }
}

extension TripRepository: QueuedOperationExecutor {
    public func execute(_ item: QueuedItem) async throws {
        switch item.operation {
        case let .savePlace(tripID, label, category, placeID, source):
            _ = try await savePlace(tripID: tripID, label: label, category: category, placeID: placeID, source: source, clientOpID: item.id)
        case let .setInterest(savedID, interested):
            try await setInterest(savedID: savedID, interested: interested)
        case let .recordPurchase(itemID, purchased):
            try await recordPurchase(itemID: itemID, purchased: purchased, clientOpID: item.id)
        }
    }
}
