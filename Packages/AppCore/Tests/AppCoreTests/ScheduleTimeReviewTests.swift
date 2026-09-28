import Foundation
import Testing
@testable import AppCore

struct ScheduleTimeReviewTests {
    func stop(_ order: Int, _ start: String?, dwell: Int? = 60, end: String? = nil, fixed: Bool = false) -> Stop {
        Stop(id: UUID(), tripId: UUID(), dayId: UUID(), placeId: nil, rawLabel: "站點\(order)",
             resolutionStatus: .pendingText, startTime: start, endTime: end, dwellMinutes: dwell,
             fixed: fixed, kind: .standard, sortOrder: order, revision: 0)
    }
    @Test func unlocatedStopStillConflictsWithFixedTime() {
        let result = ScheduleTimeReview.issues(in: [stop(0,"10:00"),stop(1,"10:30",fixed:true)])
        #expect(result.count == 1)
        #expect(result[0].message.contains("固定行程"))
    }
    @Test func unknownDurationIsNotZeroOrDeclaredSafe() {
        let stops = [stop(0,"10:00",dwell:nil),stop(1,"11:00")]
        #expect(ScheduleTimeReview.issues(in: stops).isEmpty)
        #expect(ScheduleTimeReview.unknownTimeCount(in: stops) == 1)
    }
    @Test func explicitEndTakesPriorityOverDwell() {
        #expect(ScheduleTimeReview.issues(in: [stop(0,"10:00",end:"10:20:00"),stop(1,"10:30")]).isEmpty)
    }
    @Test func backwardOrderIsVisible() {
        #expect(ScheduleTimeReview.issues(in: [stop(0,"14:00"),stop(1,"13:00")])[0].id.hasPrefix("order:"))
    }
    @Test func midnightCrossingRequiresNextDayReview() {
        #expect(ScheduleTimeReview.issues(in: [stop(0,"23:30",end:"00:30")])[0].id.hasPrefix("overnight:"))
    }
    @Test func touchingBoundaryDoesNotInventTrafficConflict() {
        #expect(ScheduleTimeReview.issues(in: [stop(0,"10:00"),stop(1,"11:00")]).isEmpty)
    }
    @Test func secondsDoNotHideOverlap() {
        #expect(ScheduleTimeReview.issues(in: [stop(0,"10:00",end:"10:30:59"),stop(1,"10:30:00")]).count == 1)
    }
    @Test func invalidTimeStaysUnknown() {
        #expect(ScheduleTimeReview.unknownTimeCount(in: [stop(0,"25:00"),stop(1,"10:00:70")]) == 2)
    }

    func leg(_ a: Stop, _ b: Stop, _ time: LegTime) -> BaseRoute.Leg { .init(from: a.id, to: b.id, time: time) }

    @Test func knownRouteLongerThanGapNamesBothStopsAndTimes() {
        let a = stop(0, "10:00"), b = stop(1, "11:10", fixed: true)
        let issues = ScheduleTimeReview.travelIssues(in: [a, b], legs: [leg(a, b, .minutes(24.2))])
        #expect(issues.count == 1)
        #expect(issues[0].id.hasPrefix("late:"))
        #expect(issues[0].message.contains("站點0") && issues[0].message.contains("站點1"))
        #expect(issues[0].message.contains("11:00") && issues[0].message.contains("11:10"))
        #expect(issues[0].message.contains("約 25 分鐘") && issues[0].message.contains("晚到約 15 分鐘"))
    }
    @Test func enoughGapIsNotFlagged() {
        let a = stop(0, "10:00"), b = stop(1, "11:30")
        #expect(ScheduleTimeReview.travelIssues(in: [a, b], legs: [leg(a, b, .minutes(30))]).isEmpty)
    }
    @Test func unknownLegBeforeFixedStopIsNeverReachable() {
        let a = stop(0, "10:00"), b = stop(1, "13:00", fixed: true)
        let unavailable = ScheduleTimeReview.travelIssues(in: [a, b], legs: [leg(a, b, .unavailable(.unknown))])
        #expect(unavailable.first?.id.hasPrefix("travel_unknown:") == true)
        // 未定位站點沒有路段，也不能當成零分鐘。
        #expect(ScheduleTimeReview.travelIssues(in: [a, b], legs: []).first?.message.contains("無法估算") == true)
    }
    @Test func unknownLegBetweenFlexibleStopsStaysInUnknownCountOnly() {
        let a = stop(0, "10:00"), b = stop(1, "13:00")
        #expect(ScheduleTimeReview.travelIssues(in: [a, b], legs: []).isEmpty)
    }
    @Test func legSkippingUnlocatedStopIsNotUsedForAdjacentPair() {
        let a = stop(0, "10:00"), pending = stop(1, "11:05", fixed: true), c = stop(2, "12:30")
        let issues = ScheduleTimeReview.travelIssues(in: [a, pending, c], legs: [leg(a, c, .minutes(5))])
        #expect(issues.map(\.id).allSatisfy { $0.hasPrefix("travel_unknown:") })
        #expect(issues.count == 2)
    }
    @Test func overlapAndOvernightAreLeftToTimeIssues() {
        let a = stop(0, "10:00"), b = stop(1, "10:30")
        #expect(ScheduleTimeReview.travelIssues(in: [a, b], legs: [leg(a, b, .minutes(60))]).isEmpty)
        let night = stop(0, "23:30", end: "00:30"), next = stop(1, "09:00", fixed: true)
        #expect(ScheduleTimeReview.travelIssues(in: [night, next], legs: []).isEmpty)
    }
}
