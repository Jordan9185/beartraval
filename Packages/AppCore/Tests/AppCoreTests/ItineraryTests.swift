import Foundation
import Testing
@testable import AppCore

struct ItineraryTests {
    let tripID = UUID()
    let day1 = UUID(), day2 = UUID()

    func day(_ id: UUID, _ order: Int) -> TripDay {
        TripDay(id: id, tripId: tripID, localDate: "2026-10-0\(order + 1)", transportMode: .transit, displayOrder: order, routeRevision: 0)
    }

    func stop(_ day: UUID, _ order: Int, place: UUID? = UUID()) -> Stop {
        Stop(id: UUID(), tripId: tripID, dayId: day, placeId: place, rawLabel: "S\(order)",
             resolutionStatus: place == nil ? .pendingText : .resolved, startTime: nil, endTime: nil,
             dwellMinutes: nil, fixed: false, kind: .standard, sortOrder: order, revision: 0)
    }

    @Test func groupsStopsByDayInOrderAndKeepsEmptyDays() {
        let s = [stop(day1, 1), stop(day1, 0)]
        let timeline = DayTimeline.build(days: [day(day2, 1), day(day1, 0)], stops: s)
        #expect(timeline.map(\.day.id) == [day1, day2])
        #expect(timeline[0].stops.map(\.sortOrder) == [0, 1])
        #expect(timeline[1].stops.isEmpty)
    }

    @Test func pendingStopsDoNotCountTowardRoute() {
        let timeline = DayTimeline(day: day(day1, 0), stops: [stop(day1, 0), stop(day1, 1, place: nil)])
        #expect(timeline.pendingCount == 1)
        #expect(timeline.routableCount == 1)
        #expect(timeline.routeStatus == .notEnoughPlaces)
    }

    @Test func twoConfirmedPlacesAreCalculableButNotCalculated() {
        let timeline = DayTimeline(day: day(day1, 0), stops: [stop(day1, 0), stop(day1, 1)])
        #expect(timeline.routeStatus == .notCalculated)
    }

    @Test func stopDraftEncodesSnakeCaseAndOmitsNil() throws {
        let draft = StopDraft(rawLabel: "광장시장", startTime: "09:00", fixed: true)
        let json = try #require(String(data: JSONEncoder().encode(draft), encoding: .utf8))
        #expect(json.contains("\"raw_label\":\"광장시장\""))
        #expect(json.contains("\"start_time\":\"09:00\""))
        #expect(!json.contains("place_id"))
        #expect(!json.contains("\"id\""))
    }

    @Test func draftFromStopKeepsIdAndTrimsSeconds() {
        var s = stop(day1, 0)
        s.startTime = "09:30:00"
        let draft = StopDraft(s)
        #expect(draft.id == s.id)
        #expect(draft.startTime == "09:30")
        #expect(draft.placeId == s.placeId)
    }

    @Test func stopDecodesFromPostgRESTRow() throws {
        let json = #"{"id":"6f9619ff-8b86-d011-b42d-00c04fc964f1","trip_id":"6f9619ff-8b86-d011-b42d-00c04fc964f2","day_id":"6f9619ff-8b86-d011-b42d-00c04fc964f3","place_id":null,"raw_label":"카페 (지점 미정)","resolution_status":"pending_text","start_time":"14:00:00","end_time":null,"dwell_minutes":null,"fixed":false,"kind":"standard","sort_order":2,"added_by":"6f9619ff-8b86-d011-b42d-00c04fc964f4","revision":0,"created_at":"2026-09-24T00:00:00Z","updated_at":"2026-09-24T00:00:00Z","deleted_at":null}"#
        let stop = try JSONDecoder().decode(Stop.self, from: Data(json.utf8))
        #expect(stop.resolutionStatus == .pendingText)
        #expect(!stop.isRoutable)
        #expect(stop.startTime == "14:00:00")
    }
}

struct DayPlanTests {
    @Test func buildsPlanFromTimelineExcludingPendingStops() throws {
        let tripID = UUID(), dayID = UUID(), placeID = UUID()
        let day = TripDay(id: dayID, tripId: tripID, localDate: "2026-10-01", transportMode: .walking, displayOrder: 0, routeRevision: 4)
        func stop(_ order: Int, place: UUID?) -> Stop {
            Stop(id: UUID(), tripId: tripID, dayId: dayID, placeId: place, rawLabel: "S\(order)",
                 resolutionStatus: place == nil ? .pendingText : .resolved, startTime: order == 0 ? "09:30:00" : nil,
                 endTime: nil, dwellMinutes: 20, fixed: order == 0, kind: .standard, sortOrder: order, revision: 0)
        }
        let place = Place(id: placeID, provider: "apple_mapkit", providerPlaceId: "x", name: "Gwangjang Market", nameLocal: "광장시장",
                          address: nil, latitude: 37.57, longitude: 126.99, countryCode: "KR")
        let timeline = DayTimeline(day: TripDay(id: dayID, tripId: tripID, localDate: "2026-10-01", transportMode: .walking, displayOrder: 0, routeRevision: 4, timeZone: "Asia/Seoul"),
                                   stops: [stop(0, place: placeID), stop(1, place: nil)])
        _ = day
        let plan = try #require(DayPlan.from(timeline, places: [placeID: place]))
        #expect(plan.stops.count == 1)
        #expect(plan.excludedPendingCount == 1)
        #expect(plan.stops[0].startMinutes == 570)
        #expect(plan.stops[0].label == "광장시장")
        #expect(plan.stops[0].point.isInKorea)
        #expect(plan.routeRevision == 4)
        // 首爾 2026-10-01 00:00 = UTC 09-30 15:00
        #expect(plan.localMidnight == Date(timeIntervalSince1970: 1_790_780_400))
    }
}
