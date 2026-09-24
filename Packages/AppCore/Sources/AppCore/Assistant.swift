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

    public var answer: String
    public var cannotDetermine: Bool
    public var citations: [Citation]
    /// 只是建議：App 重新計算後交給使用者確認（WP5），AI 不會寫入行程。
    public var proposal: Proposal?

    enum CodingKeys: String, CodingKey {
        case answer, citations, proposal
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
    public func ask(tripID: UUID, question: String, today: String?, routeFacts: [RouteFact]) async throws -> AskResult {
        struct Body: Encodable {
            let trip_id: UUID, question: String, today: String?, route_facts: [RouteFact]
        }
        struct Response: Decodable {
            let status: String, answer: AssistantAnswer?, reason: String?
        }
        do {
            let r: Response = try await client.functions.invoke(
                "ask-trip", options: FunctionInvokeOptions(body: Body(trip_id: tripID, question: question, today: today, route_facts: routeFacts)))
            if r.status == "answered", let answer = r.answer { return .answered(answer) }
            return .failed(reason: r.reason ?? "unknown")
        } catch {
            throw BackendError.from(error)
        }
    }
}
