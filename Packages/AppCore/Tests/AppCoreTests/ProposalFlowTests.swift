import Foundation
import Testing
@testable import AppCore

/// 模擬伺服器：當日 revision、Stop 清單；confirm 時比對 revision。
final class FakeProposalService: ProposalService, @unchecked Sendable {
    let tripID = UUID(), dayID = UUID()
    var revision = 1
    var stops: [PlannedStop]
    var proposals: [UUID: ChangeProposal] = [:]
    var confirmCalls = 0
    private let lock = NSLock()

    init(stops: [PlannedStop]) { self.stops = stops }

    func loadDayPlan(tripID: UUID, dayID: UUID) async throws -> DayPlan {
        lock.withLock { DayPlan(dayID: dayID, routeRevision: revision, localMidnight: Date(timeIntervalSince1970: 0), stops: stops, excludedPendingCount: 0) }
    }

    func createProposal(dayID: UUID, expectedRouteRevision: Int, change: ProposalChange, summary: MatchSummary) async throws -> ChangeProposal {
        try lock.withLock {
            guard expectedRouteRevision == revision else { throw BackendError.staleRevision }
            let p = ChangeProposal(id: UUID(), tripId: tripID, dayId: dayID, change: change, expectedRouteRevision: expectedRouteRevision, status: .proposed)
            proposals[p.id] = p
            return p
        }
    }

    func confirm(proposalID: UUID) async throws -> ConfirmOutcome {
        lock.withLock {
            confirmCalls += 1
            let p = proposals[proposalID]!
            guard p.expectedRouteRevision == revision else { return .stale(currentRouteRevision: revision) }
            revision += 1
            return .confirmed(routeRevision: revision, stopID: UUID())
        }
    }

    func reject(proposalID: UUID) async throws {}

    /// 另一位旅伴修改了當日。
    func otherEditorChanges(_ newStops: [PlannedStop]) {
        lock.withLock { stops = newStops; revision += 1 }
    }
}

struct ProposalFlowTests {
    let a = jp(1), b = jp(2), x = jp(9), c = jp(3)

    func flow(_ service: FakeProposalService, _ table: [String: Double]) -> AddToDayFlow {
        AddToDayFlow(service: service, matcher: RouteMatcher(provider: FakeProvider(table)))
    }

    @Test func proposeShowsNumbersWithoutWriting() async throws {
        let service = FakeProposalService(stops: [stop(a), stop(b)])
        let f = flow(service, legs([(a, b, 10), (a, x, 4), (x, b, 8), (x, a, 50), (b, x, 50)]))
        let (pending, _) = try await f.propose(placeID: UUID(), label: "X", point: x, dwellMinutes: 30,
                                              tripID: service.tripID, dayID: service.dayID, mode: .walking)
        let p = try #require(pending)
        #expect(p.insertion.addedTravelMinutes == 2)
        #expect(p.proposal.expectedRouteRevision == 1)
        #expect(p.proposal.change.beforeStopId == service.stops[1].id)
        #expect(service.revision == 1, "proposing does not change the day")
        #expect(service.confirmCalls == 0)
    }

    @Test func confirmAddsWhenNothingChanged() async throws {
        let service = FakeProposalService(stops: [stop(a), stop(b)])
        let f = flow(service, legs([(a, b, 10), (a, x, 4), (x, b, 8)]))
        let (pending, _) = try await f.propose(placeID: UUID(), label: "X", point: x, dwellMinutes: 0,
                                              tripID: service.tripID, dayID: service.dayID, mode: .walking)
        guard case .added(let revision, _) = try await f.confirm(pending!, point: x) else { Issue.record("expected added"); return }
        #expect(revision == 2)
    }

    @Test func staleConfirmRecomputesAndAsksAgain() async throws {
        let service = FakeProposalService(stops: [stop(a), stop(b)])
        let f = flow(service, legs([(a, b, 10), (a, x, 4), (x, b, 8), (b, c, 10), (b, x, 3), (x, c, 3), (x, a, 50), (c, x, 50)]))
        let (pending, _) = try await f.propose(placeID: UUID(), label: "X", point: x, dwellMinutes: 0,
                                              tripID: service.tripID, dayID: service.dayID, mode: .walking)
        #expect(pending?.insertion.addedTravelMinutes == 2)

        // 另一位 Editor 先改了這天：A、B 後面加了 C。
        service.otherEditorChanges([stop(a), stop(b), stop(c)])

        let result = try await f.confirm(pending!, point: x)
        guard case .needsReconfirm(let fresh) = result else { Issue.record("expected reconfirm, got \(result)"); return }
        #expect(fresh.proposal.expectedRouteRevision == 2)
        #expect(fresh.proposal.id != pending!.proposal.id)
        #expect(service.confirmCalls == 1, "does not auto-confirm the recomputed proposal")
        #expect(service.revision == 2, "stale confirm wrote nothing")

        guard case .added = try await f.confirm(fresh, point: x) else { Issue.record("expected added"); return }
        #expect(service.revision == 3)
    }

    @Test func unavailableRouteCreatesNoProposal() async throws {
        let service = FakeProposalService(stops: [stop(kr), stop(kr)])
        let f = flow(service, [:])
        let (pending, match) = try await f.propose(placeID: UUID(), label: "X", point: kr, dwellMinutes: 30,
                                                  tripID: service.tripID, dayID: service.dayID, mode: .transit)
        #expect(pending == nil)
        #expect(match.result == .unavailable(.notSupportedInRegion))
        #expect(service.proposals.isEmpty)
    }

    @Test func changeUsesNeighborIDs() {
        let prev = UUID(), next = UUID()
        func ins(_ p: UUID?, _ n: UUID?) -> Insertion {
            Insertion(index: 0, previousStopID: p, nextStopID: n, addedTravelMinutes: 1, addedDwellMinutes: 30, fixedCheck: .noFixedAfter, approximate: false)
        }
        let middle = ProposalChange(insertion: ins(prev, next), placeId: UUID(), label: "X")
        #expect(middle.beforeStopId == next && middle.afterStopId == nil)
        let end = ProposalChange(insertion: ins(prev, nil), placeId: UUID(), label: "X")
        #expect(end.beforeStopId == nil && end.afterStopId == prev)
        #expect(end.dwellMinutes == 30)
    }
}
