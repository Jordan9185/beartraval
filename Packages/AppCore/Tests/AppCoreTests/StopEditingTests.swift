import Foundation
import Testing
@testable import AppCore

struct StopEditingTests {
    let tripID = UUID(), dayID = UUID()

    func stop(_ order: Int, place: UUID?, label: String) -> Stop {
        Stop(id: UUID(), tripId: tripID, dayId: dayID, placeId: place, rawLabel: label, resolutionStatus: place == nil ? .pendingText : .resolved,
             startTime: order == 0 ? "09:00:00" : nil, endTime: nil, dwellMinutes: 30, fixed: order == 0, kind: .standard, sortOrder: order, revision: 0)
    }

    var timeline: DayTimeline {
        DayTimeline(day: TripDay(id: dayID, tripId: tripID, localDate: "2026-10-01", transportMode: .walking, displayOrder: 0, routeRevision: 3),
                    stops: [stop(0, place: UUID(), label: "A"), stop(1, place: nil, label: "明洞夜市（待確認）"), stop(2, place: UUID(), label: "C")])
    }

    @Test func resolvingKeepsOtherStopsAndOrder() throws {
        let t = timeline
        let place = UUID()
        let drafts = try #require(t.drafts(applying: .resolve(placeID: place), to: t.stops[1].id))
        #expect(drafts.count == 3)
        #expect(drafts.map(\.id) == t.stops.map(\.id), "ids kept so the server updates, not recreates")
        #expect(drafts[1].placeId == place && drafts[1].rawLabel == "明洞夜市（待確認）", "user label kept as the Chinese note")
        #expect(drafts[0].placeId == t.stops[0].placeId && drafts[0].fixed && drafts[0].startTime == "09:00")
    }

    @Test func renameAndRemove() throws {
        let t = timeline
        #expect(try #require(t.drafts(applying: .rename("  夜市  "), to: t.stops[1].id))[1].rawLabel == "夜市")
        #expect(try #require(t.drafts(applying: .rename("   "), to: t.stops[1].id))[1].rawLabel == "明洞夜市（待確認）", "blank rename ignored")
        #expect(try #require(t.drafts(applying: .remove, to: t.stops[1].id)).map(\.rawLabel) == ["A", "C"])
        #expect(t.drafts(applying: .remove, to: UUID()) == nil)
    }

    @Test func legFromSkipsPendingStop() {
        let t = timeline
        let base = BaseRoute(dayID: dayID, routeRevision: 3, mode: .walking, provider: .appleMapKit,
                             legs: [.init(from: t.stops[0].id, to: t.stops[2].id, time: .minutes(12))], excludedPendingCount: 1)
        #expect(base.leg(from: t.stops[0].id)?.to == t.stops[2].id)
        #expect(base.leg(from: t.stops[1].id) == nil)
    }
}
