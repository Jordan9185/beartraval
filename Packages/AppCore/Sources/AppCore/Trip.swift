import Foundation
import Supabase

public struct Trip: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// `yyyy-MM-dd`，旅行地當地日期。
    public var startDate: String
    public var endDate: String
    public var timeZone: String
    public var revision: Int

    enum CodingKeys: String, CodingKey {
        case id, name, revision
        case startDate = "start_date"
        case endDate = "end_date"
        case timeZone = "time_zone"
    }
}

public struct TripDay: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var tripId: UUID
    public var localDate: String
    public var transportMode: TravelMode
    public var displayOrder: Int
    public var routeRevision: Int

    enum CodingKeys: String, CodingKey {
        case id
        case tripId = "trip_id"
        case localDate = "local_date"
        case transportMode = "transport_mode"
        case displayOrder = "display_order"
        case routeRevision = "route_revision"
    }
}

/// 旅行地的當地日期（Postgres `date`）。
public enum LocalDate {
    public static func string(from date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

/// Trip 讀寫。寫入一律走 RPC，由服務端檢查權限（supabase/README.md）。
public struct TripRepository: Sendable {
    let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    /// RLS 只回傳目前使用者是有效成員的 Trip。
    public func myTrips() async throws -> [Trip] {
        do {
            return try await client.from("trips").select().order("start_date", ascending: false).execute().value
        } catch {
            throw BackendError.from(error)
        }
    }

    public func days(of tripID: UUID) async throws -> [TripDay] {
        do {
            return try await client.from("trip_days").select()
                .eq("trip_id", value: tripID)
                .order("display_order")
                .execute().value
        } catch {
            throw BackendError.from(error)
        }
    }

    /// 各日（未刪除）Stop 數量。
    public func stopCounts(of tripID: UUID) async throws -> [UUID: Int] {
        struct Row: Decodable { let day_id: UUID }
        do {
            let rows: [Row] = try await client.from("stops").select("day_id")
                .eq("trip_id", value: tripID)
                .is("deleted_at", value: nil)
                .execute().value
            return rows.reduce(into: [:]) { $0[$1.day_id, default: 0] += 1 }
        } catch {
            throw BackendError.from(error)
        }
    }

    public func createTrip(name: String, startDate: String, endDate: String, timeZone: String) async throws -> Trip {
        struct Params: Encodable {
            let p_name: String
            let p_start_date: String
            let p_end_date: String
            let p_time_zone: String
        }
        do {
            return try await client.rpc("create_trip", params: Params(
                p_name: name, p_start_date: startDate, p_end_date: endDate, p_time_zone: timeZone
            )).execute().value
        } catch {
            throw BackendError.from(error)
        }
    }
}
