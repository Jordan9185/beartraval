import Foundation
import Supabase

// MARK: - AI 解析草稿（對應 ai/itinerary-parse/src/schema.ts）

public struct ParseDraft: Codable, Hashable, Sendable {
    public var days: [Day]
    public var cityCandidates: [String]
    public var warnings: [String]

    public init(days: [Day], cityCandidates: [String], warnings: [String]) {
        self.days = days
        self.cityCandidates = cityCandidates
        self.warnings = warnings
    }

    public struct Day: Codable, Hashable, Sendable {
        public var date: String?
        public var dayLabel: String?
        public var stops: [ParsedStop]

        public init(date: String?, dayLabel: String?, stops: [ParsedStop]) {
            self.date = date
            self.dayLabel = dayLabel
            self.stops = stops
        }

        enum CodingKeys: String, CodingKey {
            case date, stops
            case dayLabel = "day_label"
        }
    }

    enum CodingKeys: String, CodingKey {
        case days, warnings
        case cityCandidates = "city_candidates"
    }
}

public struct ParsedStop: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case ambiguousBranch = "ambiguous_branch"
        case unknownPlace = "unknown_place"
        case ambiguousDate = "ambiguous_date"
        case ambiguousTime = "ambiguous_time"
    }

    public var sourceExcerpt: String
    public var placeName: String?
    public var branchHint: String?
    /// 地點所在城市（英文，例如 "Onomichi"），用來把地圖搜尋限定在那一帶。
    public var city: String?
    public var searchQuery: String?
    public var category: String
    public var startTime: String?
    public var endTime: String?
    public var timeIsApproximate: Bool
    public var fixedSuspected: Bool
    public var fixedReason: String?
    public var confidence: String
    public var needsConfirmation: [Reason]

    public init(sourceExcerpt: String, placeName: String?, branchHint: String? = nil, city: String? = nil, searchQuery: String? = nil,
                category: String = "place", startTime: String? = nil, endTime: String? = nil, timeIsApproximate: Bool = false,
                fixedSuspected: Bool = false, fixedReason: String? = nil, confidence: String = "high", needsConfirmation: [Reason] = []) {
        self.sourceExcerpt = sourceExcerpt
        self.placeName = placeName
        self.branchHint = branchHint
        self.city = city
        self.searchQuery = searchQuery
        self.category = category
        self.startTime = startTime
        self.endTime = endTime
        self.timeIsApproximate = timeIsApproximate
        self.fixedSuspected = fixedSuspected
        self.fixedReason = fixedReason
        self.confidence = confidence
        self.needsConfirmation = needsConfirmation
    }

    enum CodingKeys: String, CodingKey {
        case category, confidence, city
        case sourceExcerpt = "source_excerpt"
        case placeName = "place_name"
        case branchHint = "branch_hint"
        case searchQuery = "search_query"
        case startTime = "start_time"
        case endTime = "end_time"
        case timeIsApproximate = "time_is_approximate"
        case fixedSuspected = "fixed_suspected"
        case fixedReason = "fixed_reason"
        case needsConfirmation = "needs_confirmation"
    }

    /// 停留預設（§4.2）：Cafe 45、Eat 60、Shop 30、其他 60。
    public var defaultDwellMinutes: Int? {
        switch category {
        case "cafe": 45
        case "eat": 60
        case "shop": 30
        case "place": 60
        default: nil
        }
    }
}

// MARK: - ImportSession

/// 解析進度：AI 還在閱讀（reading），或已開始寫出草稿（writing）。
public struct ParseProgress: Codable, Hashable, Sendable {
    public var stage: String
    public var days: Int
    public var stops: Int
    public var lastPlace: String?

    public init(stage: String, days: Int = 0, stops: Int = 0, lastPlace: String? = nil) {
        self.stage = stage
        self.days = days
        self.stops = stops
        self.lastPlace = lastPlace
    }

    enum CodingKeys: String, CodingKey {
        case stage, days, stops
        case lastPlace = "last_place"
    }
}

public struct ImportSession: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, parsing, parsed, failed
    }

    public struct Stored: Codable, Hashable, Sendable {
        public var draft: ParseDraft

        public init(draft: ParseDraft) {
            self.draft = draft
        }
    }

    public var id: UUID
    public var tripName: String
    public var startDate: String
    public var endDate: String
    public var timeZone: String
    /// 使用者貼上的原文，解析失敗也保留（規格 §3.1）。
    public var rawText: String
    public var parseStatus: Status
    public var parseResult: Stored?
    public var parseError: String?
    /// 解析中的進度（服務端邊串流邊寫入）。
    public var parseProgress: ParseProgress?
    public var tripId: UUID?

    public init(id: UUID, tripName: String, startDate: String, endDate: String, timeZone: String, rawText: String,
                parseStatus: Status, parseResult: Stored? = nil, parseError: String? = nil, tripId: UUID? = nil) {
        self.id = id
        self.tripName = tripName
        self.startDate = startDate
        self.endDate = endDate
        self.timeZone = timeZone
        self.rawText = rawText
        self.parseStatus = parseStatus
        self.parseResult = parseResult
        self.parseError = parseError
        self.tripId = tripId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case tripName = "trip_name"
        case startDate = "start_date"
        case endDate = "end_date"
        case timeZone = "time_zone"
        case rawText = "raw_text"
        case parseStatus = "parse_status"
        case parseResult = "parse_result"
        case parseError = "parse_error"
        case parseProgress = "parse_progress"
        case tripId = "trip_id"
    }

    /// 旅程內所有日期（`yyyy-MM-dd`）。
    public var tripDates: [String] {
        guard let tz = TimeZone(identifier: timeZone), let start = LocalDate.midnight(startDate, in: tz),
              let end = LocalDate.midnight(endDate, in: tz) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        var dates: [String] = []
        var day = start
        while day <= end {
            dates.append(LocalDate.string(from: day, timeZone: tz))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return dates
    }
}

/// `commit_import` 的一天。
public struct ImportDayCommit: Encodable, Equatable, Sendable {
    public var date: String
    public var stops: [StopDraft]
}

// MARK: - 服務介面（UI 測試可替換）

public protocol ImportService: Sendable {
    func createImport(tripName: String, startDate: String, endDate: String, timeZone: String, rawText: String) async throws -> ImportSession
    func updateText(importID: UUID, rawText: String) async throws -> ImportSession
    /// 觸發 AI 解析，回傳更新後的 session（parsed 或 failed）。
    func parse(importID: UUID) async throws -> ImportSession
    /// 讀取目前狀態（解析中輪詢進度用）。
    func session(importID: UUID) async throws -> ImportSession
    func registerPlace(_ draft: PlaceDraft) async throws -> Place
    func commit(importID: UUID, days: [ImportDayCommit]) async throws -> Trip
}

public struct SupabaseImportService: ImportService {
    let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func createImport(tripName: String, startDate: String, endDate: String, timeZone: String, rawText: String) async throws -> ImportSession {
        struct Params: Encodable {
            let p_trip_name: String, p_start_date: String, p_end_date: String, p_time_zone: String, p_raw_text: String
        }
        return try await call("create_import", Params(p_trip_name: tripName, p_start_date: startDate, p_end_date: endDate,
                                                      p_time_zone: timeZone, p_raw_text: rawText))
    }

    public func updateText(importID: UUID, rawText: String) async throws -> ImportSession {
        struct Params: Encodable { let p_import_id: UUID, p_raw_text: String }
        return try await call("update_import_text", Params(p_import_id: importID, p_raw_text: rawText))
    }

    public func parse(importID: UUID) async throws -> ImportSession {
        struct Body: Encodable { let import_id: UUID }
        do {
            try await client.functions.invoke("parse-import", options: FunctionInvokeOptions(body: Body(import_id: importID)))
        } catch {
            // 函式失敗時 session 仍保留原文；以資料庫狀態為準。
        }
        return try await session(importID: importID)
    }

    public func session(importID: UUID) async throws -> ImportSession {
        do {
            return try await client.from("import_sessions").select().eq("id", value: importID).single().execute().value
        } catch {
            throw BackendError.from(error)
        }
    }

    public func registerPlace(_ draft: PlaceDraft) async throws -> Place {
        try await TripRepository(client: client).upsertPlace(draft)
    }

    public func commit(importID: UUID, days: [ImportDayCommit]) async throws -> Trip {
        struct Params: Encodable { let p_import_id: UUID, p_days: [ImportDayCommit] }
        return try await call("commit_import", Params(p_import_id: importID, p_days: days))
    }

    private func call<P: Encodable & Sendable, R: Decodable>(_ fn: String, _ params: P) async throws -> R {
        do {
            return try await client.rpc(fn, params: params).execute().value
        } catch {
            throw BackendError.from(error)
        }
    }
}
