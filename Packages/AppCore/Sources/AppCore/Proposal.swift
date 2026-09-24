import Foundation
import Supabase

/// 插入一個 Stop 的變更內容（MVP 只支援新增）。
public struct ProposalChange: Codable, Hashable, Sendable {
    public var placeId: UUID
    public var rawLabel: String
    /// 插在這個 Stop 之前；沒有時看 `afterStopId`；兩者皆無則加在最後。
    public var beforeStopId: UUID?
    public var afterStopId: UUID?
    public var dwellMinutes: Int?
    public var kind: StopKind

    public init(placeId: UUID, rawLabel: String, beforeStopId: UUID?, afterStopId: UUID?, dwellMinutes: Int?, kind: StopKind = .standard) {
        self.placeId = placeId
        self.rawLabel = rawLabel
        self.beforeStopId = beforeStopId
        self.afterStopId = afterStopId
        self.dwellMinutes = dwellMinutes
        self.kind = kind
    }

    /// 依 Route Match 的插入位置產生；位置以相鄰 Stop 的 id 表示，伺服器依當下排序解析。
    public init(insertion: Insertion, placeId: UUID, label: String, kind: StopKind = .standard) {
        self.init(placeId: placeId, rawLabel: label,
                  beforeStopId: insertion.nextStopID, afterStopId: insertion.nextStopID == nil ? insertion.previousStopID : nil,
                  dwellMinutes: insertion.addedDwellMinutes, kind: kind)
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case placeId = "place_id"
        case rawLabel = "raw_label"
        case beforeStopId = "before_stop_id"
        case afterStopId = "after_stop_id"
        case dwellMinutes = "dwell_minutes"
    }
}

/// 建立 proposal 當下顯示給使用者的數字（稽核用）。
public struct MatchSummary: Codable, Hashable, Sendable {
    public var addedTravelMinutes: Int?
    public var addedDwellMinutes: Int
    public var fixedCheck: String
    public var fixedStopId: UUID?
    public var fixedMinutes: Int?
    public var mode: TravelMode
    public var provider: RouteProvider
    public var approximate: Bool

    public init(_ insertion: Insertion, mode: TravelMode, provider: RouteProvider) {
        addedTravelMinutes = insertion.addedTravelMinutes
        addedDwellMinutes = insertion.addedDwellMinutes
        self.mode = mode
        self.provider = provider
        approximate = insertion.approximate
        switch insertion.fixedCheck {
        case .noFixedAfter: fixedCheck = "none"
        case .slack(let id, let m): fixedCheck = "slack"; fixedStopId = id; fixedMinutes = m
        case .conflict(let id, let m): fixedCheck = "conflict"; fixedStopId = id; fixedMinutes = m
        case .unknown: fixedCheck = "unknown"
        }
    }

    enum CodingKeys: String, CodingKey {
        case mode, provider, approximate
        case addedTravelMinutes = "added_travel_minutes"
        case addedDwellMinutes = "added_dwell_minutes"
        case fixedCheck = "fixed_check"
        case fixedStopId = "fixed_stop_id"
        case fixedMinutes = "fixed_minutes"
    }
}

public struct ChangeProposal: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case proposed, confirmed, rejected, stale
    }

    public var id: UUID
    public var tripId: UUID
    public var dayId: UUID
    public var change: ProposalChange
    public var expectedRouteRevision: Int
    public var status: Status

    public init(id: UUID, tripId: UUID, dayId: UUID, change: ProposalChange, expectedRouteRevision: Int, status: Status) {
        self.id = id
        self.tripId = tripId
        self.dayId = dayId
        self.change = change
        self.expectedRouteRevision = expectedRouteRevision
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, change, status
        case tripId = "trip_id"
        case dayId = "day_id"
        case expectedRouteRevision = "expected_route_revision"
    }
}

public enum ConfirmOutcome: Equatable, Sendable {
    case confirmed(routeRevision: Int, stopID: UUID)
    /// 當日已被修改；沒有寫入。需重新計算並再次確認。
    case stale(currentRouteRevision: Int)
}

public protocol ProposalService: Sendable {
    func createProposal(dayID: UUID, expectedRouteRevision: Int, change: ProposalChange, summary: MatchSummary) async throws -> ChangeProposal
    func confirm(proposalID: UUID) async throws -> ConfirmOutcome
    func reject(proposalID: UUID) async throws
    /// 重新讀取當日（最新 revision 與 Stop），供重新計算。
    func loadDayPlan(tripID: UUID, dayID: UUID) async throws -> DayPlan
}

extension TripRepository: ProposalService {
    public func createProposal(dayID: UUID, expectedRouteRevision: Int, change: ProposalChange, summary: MatchSummary) async throws -> ChangeProposal {
        struct Params: Encodable {
            let p_day_id: UUID, p_expected_route_revision: Int, p_change: ProposalChange, p_route_match: MatchSummary
        }
        do {
            return try await client.rpc("create_proposal", params: Params(
                p_day_id: dayID, p_expected_route_revision: expectedRouteRevision, p_change: change, p_route_match: summary
            )).execute().value
        } catch {
            throw BackendError.from(error)
        }
    }

    public func confirm(proposalID: UUID) async throws -> ConfirmOutcome {
        struct Params: Encodable { let p_proposal_id: UUID }
        struct Result: Decodable { let status: String, route_revision: Int, stop_id: UUID? }
        do {
            let r: Result = try await client.rpc("confirm_proposal", params: Params(p_proposal_id: proposalID)).execute().value
            if r.status == "confirmed", let stop = r.stop_id { return .confirmed(routeRevision: r.route_revision, stopID: stop) }
            return .stale(currentRouteRevision: r.route_revision)
        } catch {
            throw BackendError.from(error)
        }
    }

    public func reject(proposalID: UUID) async throws {
        struct Params: Encodable { let p_proposal_id: UUID }
        do {
            try await client.rpc("reject_proposal", params: Params(p_proposal_id: proposalID)).execute()
        } catch {
            throw BackendError.from(error)
        }
    }

    public func loadDayPlan(tripID: UUID, dayID: UUID) async throws -> DayPlan {
        async let d = days(of: tripID)
        async let s = stops(of: tripID)
        let (allDays, allStops) = try await (d, s)
        guard let day = allDays.first(where: { $0.id == dayID }) else { throw BackendError.notFound }
        let dayStops = allStops.filter { $0.dayId == dayID }
        let placeList = try await places(ids: Array(Set(dayStops.compactMap(\.placeId))))
        let timeline = DayTimeline(day: day, stops: dayStops.sorted { $0.sortOrder < $1.sortOrder })
        guard let plan = DayPlan.from(timeline, places: Dictionary(uniqueKeysWithValues: placeList.map { ($0.id, $0) })) else {
            throw BackendError.invalid("INVALID_TIME_ZONE")
        }
        return plan
    }
}

/// 加入行程流程（AC-08、AC-13）：先算、再給使用者看、按確認才寫入；
/// 確認時若已過期，重新讀取與計算後回傳新的 proposal，**不會自動再確認**。
public struct AddToDayFlow: Sendable {
    public struct Pending: Equatable, Sendable {
        public var proposal: ChangeProposal
        public var match: DayMatch
        public var insertion: Insertion
        /// 計算時當日各 Stop 的名稱，用來說明插入位置。
        public var stopLabels: [UUID: String]
    }

    public enum ConfirmResult: Equatable, Sendable {
        case added(routeRevision: Int, stopID: UUID)
        /// 行程已被他人修改；這是重新計算後的新 proposal，需使用者再確認一次。
        case needsReconfirm(Pending)
        /// 重新計算後已無法估算或無可用位置。
        case noLongerAvailable(DayMatch)
    }

    let service: any ProposalService
    let matcher: RouteMatcher

    public init(service: any ProposalService, matcher: RouteMatcher) {
        self.service = service
        self.matcher = matcher
    }

    /// 用最新的當日資料計算並建立 proposal；無法估算時回傳 nil 與結果。
    public func propose(placeID: UUID, label: String, point: RoutePoint, dwellMinutes: Int,
                        tripID: UUID, dayID: UUID, mode: TravelMode) async throws -> (Pending?, DayMatch) {
        let plan = try await service.loadDayPlan(tripID: tripID, dayID: dayID)
        let match = await matcher.match(RouteCandidate(point: point, dwellMinutes: dwellMinutes), into: plan, mode: mode)
        guard let best = match.best else { return (nil, match) }
        let proposal = try await service.createProposal(
            dayID: dayID, expectedRouteRevision: plan.routeRevision,
            change: ProposalChange(insertion: best, placeId: placeID, label: label),
            summary: MatchSummary(best, mode: mode, provider: match.provider))
        let labels = Dictionary(uniqueKeysWithValues: plan.stops.map { ($0.id, $0.label) })
        return (Pending(proposal: proposal, match: match, insertion: best, stopLabels: labels), match)
    }

    public func confirm(_ pending: Pending, point: RoutePoint) async throws -> ConfirmResult {
        switch try await service.confirm(proposalID: pending.proposal.id) {
        case .confirmed(let revision, let stop):
            return .added(routeRevision: revision, stopID: stop)
        case .stale:
            let change = pending.proposal.change
            let (fresh, match) = try await propose(placeID: change.placeId, label: change.rawLabel, point: point,
                                                   dwellMinutes: pending.insertion.addedDwellMinutes,
                                                   tripID: pending.proposal.tripId, dayID: pending.proposal.dayId,
                                                   mode: pending.match.mode)
            return fresh.map(ConfirmResult.needsReconfirm) ?? .noLongerAvailable(match)
        }
    }
}
