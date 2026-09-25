import Foundation
import Testing
@testable import AppCore

struct ConfirmPlacesTests {
    let session = ImportSession(id: UUID(), tripName: "Seoul", startDate: "2026-10-01", endDate: "2026-10-02",
                                timeZone: "Asia/Seoul", rawText: "...", parseStatus: .parsed)

    func option(_ id: String, _ name: String) -> PlaceOption {
        PlaceOption(draft: PlaceDraft(providerPlaceId: id, name: name, latitude: 37.5, longitude: 127, countryCode: "KR"))
    }

    var draft: ParseDraft {
        ParseDraft(days: [
            .init(date: "2026-10-01", dayLabel: "Day 1", stops: [
                ParsedStop(sourceExcerpt: "10:00 광장시장", placeName: "광장시장", category: "eat", startTime: "10:00"),
                ParsedStop(sourceExcerpt: "XXX Shoes", placeName: "XXX Shoes", category: "shop", needsConfirmation: [.ambiguousBranch]),
                ParsedStop(sourceExcerpt: "19:00 晚餐訂位", placeName: "Some Restaurant", category: "eat", startTime: "19:00", fixedSuspected: true),
            ]),
            .init(date: "2026-10-09", dayLabel: "10/9", stops: [
                ParsedStop(sourceExcerpt: "N서울타워", placeName: "N서울타워"),
            ]),
        ], cityCandidates: ["Seoul"], warnings: [])
    }

    @Test func tripDatesSpanTheTrip() {
        #expect(session.tripDates == ["2026-10-01", "2026-10-02"])
    }

    @Test func nothingIsDecidedAutomatically() {
        let state = ConfirmPlacesState(session: session, draft: draft)
        #expect(state.items.count == 4)
        #expect(state.items.allSatisfy { $0.decision == nil })
        #expect(!state.canSubmit)
        #expect(state.remainingCount == 4)
    }

    @Test func ambiguousBranchBlocksSubmitUntilChosen() {
        var state = ConfirmPlacesState(session: session, draft: draft)
        state.items[0].decision = .place(option("gj", "광장시장"))
        state.items[2].decision = .place(option("r", "Some Restaurant"))
        state.items[2].fixed = true
        state.items[3].decision = .remove
        #expect(state.items[1].blockers == [.undecided])
        #expect(!state.canSubmit)

        state.items[1].decision = .place(option("shoes-seongsu", "XXX Shoes 성수점"))
        #expect(state.canSubmit)
    }

    @Test func fixedCandidateMustBeConfirmed() {
        var state = ConfirmPlacesState(session: session, draft: draft)
        #expect(state.items[2].fixed == nil)
        #expect(state.items[0].fixed == false)
        state.items[2].decision = .pendingText
        #expect(state.items[2].blockers == [.fixedUnconfirmed])
        state.items[2].fixed = false
        #expect(state.items[2].blockers.isEmpty)
    }

    @Test func outOfTripDateNeedsADate() {
        var state = ConfirmPlacesState(session: session, draft: draft)
        #expect(state.items[3].date == nil)
        state.items[3].decision = .pendingText
        #expect(state.items[3].blockers == [.missingDate])
        state.items[3].date = "2026-10-02"
        #expect(state.items[3].blockers.isEmpty)
    }

    @Test func commitKeepsPendingTextWithoutPlaceAndSkipsRemoved() {
        var state = ConfirmPlacesState(session: session, draft: draft)
        let market = option("gj", "광장시장")
        state.items[0].decision = .place(market)
        state.items[1].decision = .pendingText
        state.items[2].decision = .remove
        state.items[3].decision = .place(market)
        state.items[3].date = "2026-10-02"
        #expect(state.placesToRegister.map(\.providerPlaceId) == ["gj"])

        let placeID = UUID()
        let days = state.commitDays(placeIDs: ["gj": placeID])
        #expect(days.map(\.date) == ["2026-10-01", "2026-10-02"])
        #expect(days[0].stops.count == 2)
        #expect(days[0].stops[0].placeId == placeID)
        #expect(days[0].stops[0].startTime == "10:00")
        #expect(days[0].stops[0].dwellMinutes == 60)
        #expect(days[0].stops[1].placeId == nil)
        #expect(days[0].stops[1].rawLabel == "XXX Shoes")
        #expect(days[1].stops[0].placeId == placeID)
    }

    @Test func draftDecodesFromParserOutput() throws {
        let json = #"{"draft":{"days":[{"date":"2026-10-01","day_label":"Day 1","stops":[{"source_excerpt":"XXX Shoes","place_name":"XXX Shoes","branch_hint":null,"search_query":"XXX Shoes Seoul","category":"shop","start_time":null,"end_time":null,"time_is_approximate":false,"fixed_suspected":false,"fixed_reason":null,"confidence":"medium","needs_confirmation":["ambiguous_branch"]}]}],"city_candidates":["Seoul"],"warnings":[]},"issues":[]}"#
        let stored = try JSONDecoder().decode(ImportSession.Stored.self, from: Data(json.utf8))
        #expect(stored.draft.days[0].stops[0].needsConfirmation == [.ambiguousBranch])
    }

    @Test func flightsAndUnnamedItemsStartAsText() {
        let mixed = ParseDraft(days: [
            .init(date: "2026-10-01", dayLabel: "Day 1", stops: [
                ParsedStop(sourceExcerpt: "09:20 BR156", placeName: "長榮 BR156", category: "transport", startTime: "09:20", fixedSuspected: true),
                ParsedStop(sourceExcerpt: "晚餐留白", placeName: nil, category: "eat"),
                ParsedStop(sourceExcerpt: "MAKMADE", placeName: "MAKMADE", city: "Seoul", searchQuery: "MAKMADE 성수", category: "shop"),
            ]),
        ], cityCandidates: ["Seoul"], warnings: [])
        var state = ConfirmPlacesState(session: session, draft: mixed)
        #expect(state.items.map(\.needsSearch) == [false, false, true])
        #expect(state.items[0].decision == .pendingText)
        #expect(state.items[1].decision == .pendingText)
        #expect(state.items[2].decision == nil)
        #expect(state.undecidedCount == 1)
        #expect(state.unconfirmedFixedCount == 1)

        state.keepUndecidedAsText()
        state.confirmSuspectedFixed()
        #expect(state.items[2].decision == .pendingText)
        #expect(state.items[0].fixed == true)
        #expect(state.canSubmit)
    }

    @Test func decodesCityAndParseProgress() throws {
        let json = #"{"id":"6f1c3b1e-0000-4000-8000-000000000001","trip_name":"t","start_date":"2026-10-23","end_date":"2026-10-29","time_zone":"Asia/Seoul","raw_text":"x","parse_status":"parsing","parse_result":null,"parse_error":null,"parse_progress":{"stage":"writing","days":3,"stops":18,"last_place":"大久野島"},"trip_id":null}"#
        let session = try JSONDecoder().decode(ImportSession.self, from: Data(json.utf8))
        #expect(session.parseProgress == ParseProgress(stage: "writing", days: 3, stops: 18, lastPlace: "大久野島"))
        let stop = try JSONDecoder().decode(ParsedStop.self, from: Data(#"{"source_excerpt":"尾道","place_name":"尾道","branch_hint":null,"city":"Onomichi","search_query":"尾道","category":"place","start_time":null,"end_time":null,"time_is_approximate":false,"fixed_suspected":false,"fixed_reason":null,"confidence":"high","needs_confirmation":[]}"#.utf8))
        #expect(stop.city == "Onomichi")
    }
}
