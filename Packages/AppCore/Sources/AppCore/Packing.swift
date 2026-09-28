import Foundation
import Supabase

public struct PackingItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var trip_id: UUID
    public var owner_id: UUID
    public var shared: Bool
    public var name: String
    public var quantity: Int
    public var note: String
    public var packed: Bool
    public var carrier_id: UUID?
    public var buyer_id: UUID?
    public var updated_by: UUID?
    public var revision: Int
    public var purchase_timing: String? = nil
    public var shopping_item_id: UUID? = nil

    public init(tripID: UUID, ownerID: UUID, shared: Bool = false) {
        id = UUID(); trip_id = tripID; owner_id = ownerID; self.shared = shared
        name = ""; quantity = 1; note = ""; packed = false; revision = 0
    }

    public func needsRepacking(comparedTo old: PackingItem) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != old.name || quantity > old.quantity || carrier_id != old.carrier_id
    }
}

extension TripRepository {
    public func packingItems(tripID: UUID) async throws -> [PackingItem] {
        do { return try await client.from("packing_items").select().eq("trip_id", value: tripID)
            .is("deleted_at", value: nil).order("updated_at").execute().value }
        catch { throw BackendError.from(error) }
    }

    public func savePackingItem(_ item: PackingItem, deleted: Bool = false, operationID: UUID = UUID()) async throws -> PackingItem {
        struct Params: Encodable {
            let p_id: UUID, p_trip_id: UUID, p_expected_revision: Int
            let p_name: String, p_quantity: Int, p_note: String, p_shared: Bool, p_packed: Bool
            let p_carrier_id: UUID?, p_buyer_id: UUID?, p_deleted: Bool, p_client_op_id: UUID
        }
        do { return try await client.rpc("save_packing_item", params: Params(
            p_id: item.id, p_trip_id: item.trip_id, p_expected_revision: item.revision, p_name: item.name,
            p_quantity: item.quantity, p_note: item.note, p_shared: item.shared, p_packed: item.packed,
            p_carrier_id: item.carrier_id, p_buyer_id: item.buyer_id, p_deleted: deleted, p_client_op_id: operationID)).execute().value }
        catch { throw BackendError.from(error) }
    }

    public func archivedTripIDs() async throws -> Set<UUID> {
        struct Row: Decodable { let trip_id: UUID }
        do {
            let rows: [Row] = try await client.from("trip_archives").select("trip_id").execute().value
            return Set(rows.map(\.trip_id))
        } catch { throw BackendError.from(error) }
    }

    public func setTripArchived(_ id: UUID, archived: Bool) async throws {
        struct Params: Encodable { let p_trip_id: UUID; let p_archived: Bool }
        do { try await client.rpc("set_trip_archived", params: Params(p_trip_id: id, p_archived: archived)).execute() }
        catch { throw BackendError.from(error) }
    }
}

public struct PersonalPurchase: Codable, Identifiable, Sendable {
    public var id: UUID
    public var trip_id: UUID
    public var name: String
    public var desired_quantity: Int
    public var bought_quantity: Int
    public var purchase_timing: String
    public var revision: Int
}

extension TripRepository {
    public func requestPackingPurchase(_ item: PackingItem, beforeTrip: Bool) async throws {
        struct Params: Encodable { let p_item_id: UUID; let p_expected_revision: Int; let p_timing: String }
        do { try await client.rpc("request_packing_purchase", params: Params(p_item_id: item.id, p_expected_revision: item.revision,
            p_timing: beforeTrip ? "before_trip" : "during_trip")).execute() }
        catch { throw BackendError.from(error) }
    }
    public func personalPurchases() async throws -> [PersonalPurchase] {
        do { return try await client.from("personal_purchases").select().execute().value }
        catch { throw BackendError.from(error) }
    }
    public func setPersonalPurchase(_ item: PersonalPurchase, operationID: UUID = UUID()) async throws {
        struct Params: Encodable { let p_id: UUID; let p_expected_revision: Int; let p_desired: Int; let p_bought: Int; let p_operation_id: UUID }
        do { try await client.rpc("set_personal_purchase", params: Params(p_id: item.id, p_expected_revision: item.revision,
            p_desired: item.desired_quantity, p_bought: item.bought_quantity, p_operation_id: operationID)).execute() }
        catch { throw BackendError.from(error) }
    }
}

public enum PackingSuggestions {
    public static let question = "依旅程目的地、天數與活動提出旅行必備用品 packing_suggestions。每項附數量與理由。只建議，不自動加入清單。"
    private static func key(trip: UUID, owner: UUID, shared: Bool) -> String { "packing-skipped-\(owner)-\(trip)-\(shared)" }
    public static func skipped(trip: UUID, owner: UUID, shared: Bool) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(trip: trip, owner: owner, shared: shared)) ?? [])
    }
    public static func skip(_ name: String, trip: UUID, owner: UUID, shared: Bool) {
        var names = skipped(trip: trip, owner: owner, shared: shared); names.insert(name.lowercased())
        UserDefaults.standard.set(Array(names), forKey: key(trip: trip, owner: owner, shared: shared))
    }
}
extension TripRepository {
    public func latestPackingSuggestions(tripID: UUID) async throws -> [AssistantAnswer.PackingSuggestion] {
        struct Row: Decodable { let answer: AssistantAnswer? }
        let rows: [Row] = try await client.from("ai_messages").select("answer").eq("trip_id", value: tripID)
            .eq("question", value: PackingSuggestions.question).eq("status", value: "answered")
            .order("created_at", ascending: false).limit(1).execute().value
        return rows.first?.answer?.packingSuggestions ?? []
    }
}
