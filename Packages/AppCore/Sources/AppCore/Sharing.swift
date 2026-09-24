import Foundation
import Supabase

public enum TripRole: String, Codable, CaseIterable, Sendable {
    case owner, editor, viewer

    public var displayName: String {
        switch self {
        case .owner: "擁有者"
        case .editor: "可編輯"
        case .viewer: "僅檢視"
        }
    }

    /// 新增 Saved／Shopping、提出與確認行程變更（§3.3）。
    public var canEdit: Bool { self != .viewer }
    public var canManageMembers: Bool { self == .owner }
}

public struct TripMember: Identifiable, Hashable, Sendable {
    public var userID: UUID
    public var role: TripRole
    public var displayName: String
    public var id: UUID { userID }
}

/// 邀請連結：網頁預覽（決策 D4）與 App 內開啟。
public enum InviteLink {
    public static func webURL(token: String, backend: URL) -> URL {
        var c = URLComponents(url: backend.appending(path: "functions/v1/invite"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "token", value: token)]
        return c.url!
    }

    public static func appURL(token: String) -> URL {
        URL(string: "beartravel://invite?token=\(token)")!
    }

    /// 從 App 連結、網頁連結或直接貼上的 token 取出 token。
    public static func token(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil { return trimmed }
        guard let url = URL(string: trimmed),
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value,
              token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        return token
    }
}

extension TripRepository {
    public func myRole(in tripID: UUID) async throws -> TripRole? {
        struct Params: Encodable { let p_trip_id: UUID }
        do {
            return try await client.rpc("trip_role_of", params: Params(p_trip_id: tripID)).execute().value
        } catch {
            throw BackendError.from(error)
        }
    }

    public func members(of tripID: UUID) async throws -> [TripMember] {
        struct Row: Decodable { let user_id: UUID, role: TripRole, status: String }
        struct Profile: Decodable { let user_id: UUID, display_name: String }
        do {
            let rows: [Row] = try await client.from("trip_members").select().eq("trip_id", value: tripID).eq("status", value: "active").execute().value
            let profiles: [Profile] = try await client.from("profiles").select().in("user_id", values: rows.map(\.user_id.uuidString)).execute().value
            let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.user_id, $0.display_name) })
            return rows.map { TripMember(userID: $0.user_id, role: $0.role, displayName: names[$0.user_id] ?? "旅伴") }
                .sorted { ($0.role == .owner ? 0 : 1, $0.displayName) < ($1.role == .owner ? 0 : 1, $1.displayName) }
        } catch {
            throw BackendError.from(error)
        }
    }

    /// 回傳一次性的明文 token（DB 只存雜湊）。
    public func createInvite(tripID: UUID, role: TripRole) async throws -> String {
        struct Params: Encodable { let p_trip_id: UUID, p_role: TripRole }
        do { return try await client.rpc("create_invite", params: Params(p_trip_id: tripID, p_role: role)).execute().value }
        catch { throw BackendError.from(error) }
    }

    public func acceptInvite(token: String) async throws -> UUID {
        struct Params: Encodable { let p_token: String }
        do { return try await client.rpc("accept_invite", params: Params(p_token: token)).execute().value }
        catch { throw BackendError.from(error) }
    }

    public func setMemberRole(tripID: UUID, userID: UUID, role: TripRole) async throws {
        struct Params: Encodable { let p_trip_id: UUID, p_user_id: UUID, p_role: TripRole }
        do { try await client.rpc("set_member_role", params: Params(p_trip_id: tripID, p_user_id: userID, p_role: role)).execute() }
        catch { throw BackendError.from(error) }
    }

    public func removeMember(tripID: UUID, userID: UUID) async throws {
        struct Params: Encodable { let p_trip_id: UUID, p_user_id: UUID }
        do { try await client.rpc("remove_member", params: Params(p_trip_id: tripID, p_user_id: userID)).execute() }
        catch { throw BackendError.from(error) }
    }

    public func setDisplayName(_ name: String) async throws {
        struct Params: Encodable { let p_name: String }
        do { try await client.rpc("set_display_name", params: Params(p_name: name)).execute() }
        catch { throw BackendError.from(error) }
    }

    /// 斷線重連後補拉：`since` 之後的變更事件。
    public func changes(of tripID: UUID, since revision: Int) async throws -> [TripEvent] {
        struct Params: Encodable { let p_trip_id: UUID, p_since_revision: Int }
        do { return try await client.rpc("get_trip_changes", params: Params(p_trip_id: tripID, p_since_revision: revision)).execute().value }
        catch { throw BackendError.from(error) }
    }

    public func tripRevision(_ tripID: UUID) async throws -> Int {
        struct Row: Decodable { let revision: Int }
        do {
            let rows: [Row] = try await client.from("trips").select("revision").eq("id", value: tripID).execute().value
            guard let row = rows.first else { throw BackendError.notFound }
            return row.revision
        } catch {
            throw BackendError.from(error)
        }
    }
}

public struct TripEvent: Codable, Hashable, Sendable {
    public var tripId: UUID
    public var revision: Int
    public var kind: String
    public var entityId: UUID?
    public var actorId: UUID?

    enum CodingKeys: String, CodingKey {
        case revision, kind
        case tripId = "trip_id"
        case entityId = "entity_id"
        case actorId = "actor_id"
    }
}

/// Trip 同步（§3.2）：Realtime 只推變更通知，收到後重新拉取；
/// 重新連線時以 `since_revision` 補拉，確保收斂。
@MainActor
public final class TripSync {
    public private(set) var revision: Int
    private let tripID: UUID
    private let client: SupabaseClient
    private let repository: TripRepository
    private let onChange: @MainActor ([TripEvent]) -> Void
    private var channel: RealtimeChannelV2?
    private var tasks: [Task<Void, Never>] = []

    public init(tripID: UUID, repository: TripRepository, revision: Int, onChange: @escaping @MainActor ([TripEvent]) -> Void) {
        self.tripID = tripID
        self.repository = repository
        self.client = repository.client
        self.revision = revision
        self.onChange = onChange
    }

    public func start() async {
        let channel = client.channel("trip-\(tripID.uuidString)")
        // Realtime 的 filter 以字串比對，UUID 需用 Postgres 的小寫格式。
        let inserts = channel.postgresChange(InsertAction.self, schema: "app", table: "trip_events",
                                             filter: "trip_id=eq.\(tripID.uuidString.lowercased())")
        tasks.append(Task { [weak self] in
            for await insert in inserts {
                guard let self, let event = try? insert.decodeRecord(as: TripEvent.self, decoder: JSONDecoder()) else { continue }
                if event.revision > self.revision {
                    self.revision = event.revision
                    self.onChange([event])
                }
            }
        })
        // 每次（重新）訂閱成功都補拉一次，涵蓋斷線期間的變更。
        tasks.append(Task { [weak self] in
            for await status in channel.statusChange where status == .subscribed {
                await self?.catchUp()
            }
        })
        // 保險：Realtime 漏送（例如伺服器剛啟動、背景斷線）時，定期補拉仍會收斂。
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.catchUp()
            }
        })
        self.channel = channel
        await channel.subscribe()
    }

    public func catchUp() async {
        guard let events = try? await repository.changes(of: tripID, since: revision), let last = events.last else { return }
        revision = max(revision, last.revision)
        onChange(events)
    }

    public func stop() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        if let channel { await client.removeChannel(channel) }
        channel = nil
    }
}
