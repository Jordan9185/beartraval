import Foundation
import Supabase

/// AI 助手回答（對應 ai/trip-assistant/src/schema.ts）。
public struct AssistantAnswer: Codable, Equatable, Sendable {
    public struct Citation: Codable, Hashable, Sendable {
        public var type: String
        public var id: String
    }

    public struct Proposal: Codable, Equatable, Sendable {
        public var dayId: String
        public var savedId: String
        public var reason: String

        enum CodingKeys: String, CodingKey {
            case reason
            case dayId = "day_id"
            case savedId = "saved_id"
        }
    }

    public struct Recommendation: Codable, Equatable, Sendable {
        public struct Route: Codable, Equatable, Sendable {
            public var description: String
            public var source_url: String
            public var evidence: String
        }
        public struct Rating: Codable, Equatable, Sendable {
            public var display: String
            public var platform: String
            public var reviews: String?
            public var source_url: String
            public var evidence: String
        }
        public var name: String
        public var category: String
        public var introduction: String
        public var address_local: String?
        public var source_url: String
        public var route: Route?
        public var rating: Rating?
        public var visit_note: String
    }
    public struct ShoppingProposal: Codable, Equatable, Sendable {
        public var item_id: String
        public var day_id: String
        public var source_url: String
        public var anchor_stop_id: String
        public var reason: String
    }
    public struct PackingSuggestion: Codable, Equatable, Sendable {
        public var name: String
        public var quantity: Int
        public var reason: String
    }
    public struct Arrangement: Codable, Equatable, Sendable {
        public var kind: String
        public var start_time: String?
        public var item_id: String
        public var day_id: String
        public var source_url: String?
        public var anchor_stop_id: String?
        public var reason: String
    }
    public var arrangements: [Arrangement]?
    public var packingSuggestions: [PackingSuggestion]?
    public var shoppingProposal: ShoppingProposal?
    public var recommendations: [Recommendation]?
    public var checkedAt: String?
    public var answer: String
    public var cannotDetermine: Bool
    public var citations: [Citation]
    /// 只是建議：App 重新計算後交給使用者確認（WP5），AI 不會寫入行程。
    public var proposal: Proposal?

    enum CodingKeys: String, CodingKey {
        case answer, citations, proposal, recommendations, arrangements
        case checkedAt = "checked_at"
        case shoppingProposal = "shopping_proposal"
        case packingSuggestions = "packing_suggestions"
        case cannotDetermine = "cannot_determine"
    }
}

/// App 在裝置上算好的順路結果，提供給 AI 引用（AI 不自己估分鐘數）。
public struct RouteFact: Codable, Equatable, Sendable {
    public var id: String
    public var savedId: UUID
    public var dayId: UUID
    public var addedTravelMinutes: Int?
    public var addedDwellMinutes: Int
    public var fixedConflictMinutes: Int?

    public init(savedID: UUID, match: DayMatch) {
        id = "rf-\(savedID.uuidString.prefix(8))-\(match.dayID.uuidString.prefix(8))".lowercased()
        savedId = savedID
        dayId = match.dayID
        addedTravelMinutes = match.best?.addedTravelMinutes
        addedDwellMinutes = match.best?.addedDwellMinutes ?? 0
        if case .conflict(_, let late)? = match.best?.fixedCheck { fixedConflictMinutes = late } else { fixedConflictMinutes = nil }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case savedId = "saved_id"
        case dayId = "day_id"
        case addedTravelMinutes = "added_travel_minutes"
        case addedDwellMinutes = "added_dwell_minutes"
        case fixedConflictMinutes = "fixed_conflict_minutes"
    }
}

public enum AskResult: Equatable, Sendable {
    case answered(AssistantAnswer)
    case failed(reason: String)
}

extension TripRepository {
    public func ask(tripID: UUID, question: String, today: String?, routeFacts: [RouteFact], focusStopID: UUID? = nil) async throws -> AskResult {
        struct Body: Encodable {
            let trip_id: UUID, question: String, today: String?, route_facts: [RouteFact], focus_stop_id: UUID?
        }
        struct Response: Decodable {
            let status: String, answer: AssistantAnswer?, reason: String?
        }
        do {
            let r: Response = try await PersonalAI.invoke(client: client, function: "ask-trip", options: FunctionInvokeOptions(body: Body(trip_id: tripID, question: question, today: today, route_facts: routeFacts, focus_stop_id: focusStopID)))
            if r.status == "answered", let answer = r.answer { return .answered(answer) }
            return .failed(reason: r.reason ?? "unknown")
        } catch {
            throw BackendError.from(error)
        }
    }
}

public struct PreparedTrip: Decodable, Sendable {
    public var title: String
    public var start_date: String?
    public var end_date: String?
    public var time_zone: String?
    public var summary: String
}
extension TripRepository {
    public func prepareTrip(text: String) async throws -> PreparedTrip {
        struct Body: Encodable { let raw_text: String }
        struct Response: Decodable { let status: String; let metadata: PreparedTrip?; let reason: String? }
        let result: Response = try await PersonalAI.invoke(client: client, function: "prepare-trip", options: FunctionInvokeOptions(body: Body(raw_text: text)))
        if let metadata = result.metadata, result.status == "prepared" { return metadata }
        throw BackendError.other(PersonalAI.waitingMessage(result.reason) ?? "AI 尚未完成行程讀取，原文仍保留。")
    }
}

public struct ArrangementAction: Encodable, Sendable {
    public var kind: String
    public var item_id: UUID
    public var day_id: UUID
    public var start_time: String?
    public var source_day_id: UUID?
    public var before_stop_id: UUID?
    public var operation_id = UUID()
    public var candidate_index: Int?
    public var source_url: String?
    public var store_name: String?
    public var address_local: String?
    public init(kind: String, itemID: UUID, dayID: UUID, candidateIndex: Int? = nil, candidate: ShoppingStoreSuggestion? = nil, beforeStopID: UUID? = nil, sourceDayID: UUID? = nil, startTime: String? = nil) {
        start_time = startTime
        source_day_id = sourceDayID
        before_stop_id = beforeStopID
        self.kind = kind; item_id = itemID; day_id = dayID; candidate_index = candidateIndex
        source_url = candidate?.sourceURL; store_name = candidate?.displayName; address_local = candidate?.addressLocal
    }
}
public struct ArrangementPreview: Decodable, Sendable {
    public struct Outcome: Decodable, Sendable {
        public var status: String
        public var stop_id: UUID
        public var day_id: UUID
    }
    public var before: [DayTimeline]
    public var after: [DayTimeline]
    public var outcomes: [Outcome]?
    public var reusesExistingStop: Bool {
        let existing = Set(before.flatMap(\.stops).map(\.id))
        return (outcomes ?? []).contains { $0.status == "already_scheduled" || ($0.status == "scheduled" && existing.contains($0.stop_id)) }
    }
}

extension TripRepository {
    public func previewArrangements(tripID: UUID, actions: [ArrangementAction], revisions: [String: Int], operationID: UUID) async throws -> ArrangementPreview {
        struct Params: Encodable {
            let p_trip_id: UUID, p_actions: [ArrangementAction], p_day_revisions: [String: Int], p_operation_id: UUID
        }
        do { return try await client.rpc("preview_ai_arrangements", params: Params(p_trip_id: tripID, p_actions: actions,
            p_day_revisions: revisions, p_operation_id: operationID)).execute().value }
        catch { throw BackendError.from(error) }
    }
    public func confirmArrangements(tripID: UUID, actions: [ArrangementAction], revisions: [String: Int], operationID: UUID) async throws {
        struct Params: Encodable {
            let p_trip_id: UUID, p_actions: [ArrangementAction], p_day_revisions: [String: Int], p_operation_id: UUID
        }
        do { try await client.rpc("confirm_ai_arrangements", params: Params(p_trip_id: tripID, p_actions: actions,
            p_day_revisions: revisions, p_operation_id: operationID)).execute() }
        catch { throw BackendError.from(error) }
    }
}

extension TripRepository {
    public func suppressArrangement(kind: String, id: UUID, suppressed: Bool) async throws {
        struct Params: Encodable { let p_kind: String; let p_id: UUID; let p_suppressed: Bool }
        do { try await client.rpc("set_arrangement_suppressed", params: Params(p_kind: kind, p_id: id, p_suppressed: suppressed)).execute() }
        catch { throw BackendError.from(error) }
    }
}
