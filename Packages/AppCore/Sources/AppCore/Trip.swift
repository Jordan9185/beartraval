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

    public init(id: UUID, name: String, startDate: String, endDate: String, timeZone: String, revision: Int) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.timeZone = timeZone
        self.revision = revision
    }

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
    /// 當日時區（預設繼承 Trip，跨時區行程可不同）。
    public var timeZone: String = "UTC"

    enum CodingKeys: String, CodingKey {
        case id
        case tripId = "trip_id"
        case localDate = "local_date"
        case timeZone = "time_zone"
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

    /// 整趟 Trip 未刪除的 Stop，依日、排序。
    public func stops(of tripID: UUID) async throws -> [Stop] {
        do {
            return try await client.from("stops").select()
                .eq("trip_id", value: tripID)
                .is("deleted_at", value: nil)
                .order("sort_order")
                .execute().value
        } catch {
            throw BackendError.from(error)
        }
    }

    public func places(ids: [UUID]) async throws -> [Place] {
        guard !ids.isEmpty else { return [] }
        do {
            return try await client.from("places").select()
                .in("id", values: ids.map(\.uuidString))
                .execute().value
        } catch {
            throw BackendError.from(error)
        }
    }

    /// 以整批清單取代當日行程。`expectedRouteRevision` 與伺服器不符時丟 `.staleRevision`，且不寫入任何資料。
    /// 回傳新的 route_revision。
    public func commitItinerary(dayID: UUID, expectedRouteRevision: Int, stops: [StopDraft]) async throws -> Int {
        struct Params: Encodable {
            let p_day_id: UUID
            let p_expected_route_revision: Int
            let p_stops: [StopDraft]
        }
        do {
            return try await client.rpc("commit_itinerary", params: Params(
                p_day_id: dayID, p_expected_route_revision: expectedRouteRevision, p_stops: stops
            )).execute().value
        } catch {
            throw BackendError.from(error)
        }
    }

    public func upsertPlace(_ draft: PlaceDraft) async throws -> Place {
        struct Params: Encodable {
            let p_provider: String
            let p_provider_place_id: String
            let p_name: String
            let p_latitude: Double
            let p_longitude: Double
            let p_name_local: String?
            let p_address: String?
            let p_country_code: String?
            let p_name_zh: String?
        }
        do {
            return try await client.rpc("upsert_place", params: Params(
                p_provider: draft.provider.rawValue, p_provider_place_id: draft.providerPlaceId, p_name: draft.name,
                p_latitude: draft.latitude, p_longitude: draft.longitude, p_name_local: draft.nameLocal,
                p_address: draft.address, p_country_code: draft.countryCode, p_name_zh: draft.nameZh
            )).execute().value
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
