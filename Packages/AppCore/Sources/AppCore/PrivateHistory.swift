import Foundation

/// 退出或旅程刪除後，本人私人用品與私人採買的唯讀快照（C06）。只有本人讀得到，不含共同資料。
public struct PrivateTripHistory: Decodable, Identifiable, Equatable, Sendable {
    public struct Packing: Decodable, Equatable, Sendable {
        public let name: String
        public let quantity: Int
        public let note: String?
        public let packed: Bool
    }
    public struct Purchase: Decodable, Equatable, Sendable {
        public let name: String
        public let desired_quantity: Int
        public let bought_quantity: Int
        public let purchase_timing: String
    }
    public let id: UUID
    public let trip_name: String
    public let start_date: String?
    public let end_date: String?
    public let reason: String
    public let packing: [Packing]
    public let purchases: [Purchase]
    public let created_at: String

    public var reasonText: String { reason == "trip_deleted" ? "旅程已刪除" : "你已不在此旅程" }
}

extension TripRepository {
    public func privateHistory() async throws -> [PrivateTripHistory] {
        do {
            return try await client.from("private_trip_history")
                .select("id,trip_name,start_date,end_date,reason,packing,purchases,created_at")
                .order("created_at", ascending: false).limit(100).execute().value
        } catch { throw BackendError.from(error) }
    }
    public func deletePrivateHistory(_ id: UUID) async throws {
        struct Params: Encodable { let p_id: UUID }
        do { try await client.rpc("delete_private_history", params: Params(p_id: id)).execute() }
        catch { throw BackendError.from(error) }
    }
}
