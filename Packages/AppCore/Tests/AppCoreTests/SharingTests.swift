import Foundation
import Testing
@testable import AppCore

struct SharingTests {
    let token = String(repeating: "ab", count: 32)

    @Test func inviteLinksRoundTrip() {
        let web = InviteLink.webURL(token: token, backend: URL(string: "https://x.supabase.co")!)
        #expect(web.absoluteString == "https://x.supabase.co/functions/v1/invite?token=\(token)")
        #expect(InviteLink.token(from: web.absoluteString) == token)
        #expect(InviteLink.token(from: InviteLink.appURL(token: token).absoluteString) == token)
        #expect(InviteLink.token(from: "  \(token)\n") == token)
        #expect(InviteLink.token(from: "https://x/invite?token=short") == nil)
        #expect(InviteLink.token(from: "hello") == nil)
    }

    @Test func rolePermissions() {
        #expect(TripRole.editor.canEdit && !TripRole.viewer.canEdit)
        #expect(TripRole.owner.canManageMembers && !TripRole.editor.canManageMembers)
    }
}

final class FakeExecutor: QueuedOperationExecutor, @unchecked Sendable {
    var failures: [Error?]
    var executed: [UUID] = []
    init(_ failures: [Error?]) { self.failures = failures }
    func execute(_ item: QueuedItem) async throws {
        let next = failures.isEmpty ? nil : failures.removeFirst()
        if let next { throw next }
        executed.append(item.id)
    }
}

struct OfflineQueueTests {
    let op = QueuedOperation.setInterest(savedID: UUID(), interested: true)

    @Test func networkErrorStopsAndKeepsOrder() async {
        let queue = OfflineQueue(file: nil)
        await queue.enqueue(op)
        await queue.enqueue(op)
        let result = await queue.flush(using: FakeExecutor([nil, URLError(.notConnectedToInternet)]))
        #expect(result.sent == 1)
        #expect(result.remaining == 1)
        #expect(await queue.items.first?.attempts == 1)
    }

    @Test func serverRejectionIsDroppedAndReported() async {
        let queue = OfflineQueue(file: nil)
        await queue.enqueue(op)
        await queue.enqueue(op)
        let result = await queue.flush(using: FakeExecutor([BackendError.forbidden, nil]))
        #expect(result.rejected.count == 1)
        #expect(result.sent == 1)
        #expect(result.remaining == 0)
    }

    /// 多處同時 flush：每筆只送一次、不閃退（審查 H1）。
    @Test func overlappingFlushesSendEachItemOnce() async {
        let queue = OfflineQueue(file: nil)
        await queue.enqueue(op)
        await queue.enqueue(op)
        let executor = SlowExecutor()
        async let a = queue.flush(using: executor)
        async let b = queue.flush(using: executor)
        async let c = queue.flush(using: executor)
        let results = await [a, b, c]
        #expect(await executor.executed.count == 2)
        #expect(Set(await executor.executed).count == 2)
        #expect(results.allSatisfy { $0.remaining == 0 })
        #expect(await queue.items.isEmpty)
    }

    @Test func persistsAcrossInstances() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "queue-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        await OfflineQueue(file: file).enqueue(op)
        let reloaded = OfflineQueue(file: file)
        #expect(await reloaded.items.count == 1)
        #expect(await reloaded.items.first?.operation == op)
    }
}

actor SlowExecutor: QueuedOperationExecutor {
    var executed: [UUID] = []

    func execute(_ item: QueuedItem) async throws {
        try await Task.sleep(for: .milliseconds(50))
        executed.append(item.id)
    }
}
