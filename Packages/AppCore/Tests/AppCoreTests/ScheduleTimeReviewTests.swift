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
}
