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

    func stop(_ name: String, _ query: String?, confidence: String = "high", reasons: [ParsedStop.Reason] = []) -> ParsedStop {
        ParsedStop(sourceExcerpt: name, placeName: name, searchQuery: query, category: "place", confidence: confidence, needsConfirmation: reasons)
    }

    /// 名稱取自實際 Apple 地圖回傳（2026-09-25 首爾＋廣島行程模擬）。
    @Test func confidentMatchesFromRealSearches() {
        #expect(PlaceMatch.confident(for: stop("嚴島神社", "厳島神社"), in: [option("a", "嚴島神社")])?.id == "a")
        #expect(PlaceMatch.confident(for: stop("海上大鳥居", "厳島神社 大鳥居"), in: [option("a", "厳島神社大鳥居")])?.id == "a")
        #expect(PlaceMatch.confident(for: stop("尾道", "尾道"), in: [option("a", "尾道市")])?.id == "a")
        #expect(PlaceMatch.confident(for: stop("瀨戶田", "瀬戸田"), in: [option("a", "瀬戸田港"), option("b", "Dolce總店")])?.id == "a")
        #expect(PlaceMatch.confident(for: stop("下瀨美術館", "下瀬美術館"), in: [option("a", "下瀬美術館")])?.id == "a")
        // 完全同名勝過相近名稱。
        #expect(PlaceMatch.confident(for: stop("大三島", "大三島"), in: [option("a", "大三島"), option("b", "大三島 盛港")])?.id == "a")
    }

    @Test func unclearMatchesAreLeftToTheUser() {
        // 查到的是別的店。
        #expect(PlaceMatch.confident(for: stop("Matin Kim", "마뗑킴 성수"), in: [option("a", "媽媽旅館")]) == nil)
        #expect(PlaceMatch.confident(for: stop("宮島", "宮島"), in: [option("a", "嚴島"), option("b", "宮島SA")]) == nil)
        // 只是名稱的一小段。
        #expect(PlaceMatch.confident(for: stop("大鳥居", nil), in: [option("a", "嚴島神社大鳥居")]) == nil)
        // 分店不明、信心不足：不自動選（AC-01）。
        #expect(PlaceMatch.confident(for: stop("XXX Shoes", nil, reasons: [.ambiguousBranch]), in: [option("a", "XXX Shoes")]) == nil)
        #expect(PlaceMatch.confident(for: stop("Beidelli", nil, confidence: "medium"), in: [option("a", "Beidelli")]) == nil)
        // 同名的其他分店也在候選裡：分店不明（審查）。
        #expect(PlaceMatch.confident(for: stop("Matin Kim", nil), in: [option("a", "Matin Kim"), option("b", "Matin Kim 명동점")]) == nil)
        #expect(PlaceMatch.confident(for: stop("XXX Shoes", nil), in: [option("a", "XXX Shoes 성수점")]) == nil)
        // 兩個候選都相符（兩間分店）。
        #expect(PlaceMatch.confident(for: stop("Matin Kim", nil), in: [option("a", "Matin Kim"), option("b", "Matin Kim")]) == nil)
    }

    /// 離線或被節流不是「沒收錄」：不自動保留為文字，可重新搜尋（審查 H5）。
    @Test func searchFailureIsNotTreatedAsNotFound() {
        var state = ConfirmPlacesState(session: session, draft: draft)
        state.applySearch(.unavailable, at: 0)
        #expect(state.items[0].decision == nil && !state.items[0].autoDecided && state.items[0].searchFailed)
        #expect(state.failedSearchCount == 1)
        #expect(state.needsAttention.contains(0))
        state.resetFailedSearches()
        #expect(!state.items[0].searched && !state.items[0].searchFailed)
        state.applySearch(.notFound, at: 0)
        #expect(state.items[0].decision == .pendingText && state.items[0].autoDecided)
    }

    @Test func searchResultsDecideClearCasesOnly() {
        var state = ConfirmPlacesState(session: session, draft: draft)
        state.applySearchResults([option("gj", "광장시장")], at: 0)
        state.applySearchResults([option("m", "XXX Shoes 명동점"), option("s", "XXX Shoes 성수점")], at: 1)
        state.applySearchResults([], at: 3)
        #expect(state.items[0].decision == .place(option("gj", "광장시장")) && state.items[0].autoDecided)
        #expect(state.items[1].decision == nil)
        #expect(state.items[3].decision == .pendingText && state.items[3].autoDecided)
        #expect(state.needsAttention == [1, 2, 3])  // 3 還沒有日期（10/9 不在旅程內）
    }
}

struct LocalMapSearchTests {
    @Test func countryFromScriptThenTimeZone() {
        #expect(LocalMapCountry.guess(name: "마뗑킴 성수", timeZone: "Asia/Tokyo") == "KR")
        #expect(LocalMapCountry.guess(name: "ホテル広島空港", timeZone: "Asia/Seoul") == "JP")
        #expect(LocalMapCountry.guess(name: "MAKMADE", timeZone: "Asia/Seoul") == "KR")
        #expect(LocalMapCountry.guess(name: "大三島", timeZone: "Asia/Tokyo") == "JP")
        #expect(LocalMapCountry.guess(name: "MAKMADE", timeZone: nil) == nil)
    }

    @Test func searchLinks() {
        let link = LocalMapLink(appName: "com.example")
        #expect(link.webSearchURL(.kakao, query: "The Barnnet").absoluteString == "https://map.kakao.com/?q=The%20Barnnet")
        #expect(link.webSearchURL(.naver, query: "계루").absoluteString == "https://map.naver.com/p/search/%EA%B3%84%EB%A3%A8")
        #expect(LocalMapLink.googleSearchURL(query: "Azumi Setoda", appInstalled: false).absoluteString
                == "https://www.google.com/maps/search/?api=1&query=Azumi%20Setoda")
        #expect(LocalMapLink.googleSearchURL(query: "尾道", appInstalled: true).absoluteString.hasPrefix("comgooglemaps://?q="))
    }
}

struct SearchAreasTests {
    func place(_ name: String, _ lat: Double, _ lng: Double, _ cc: String) -> Place {
        Place(id: UUID(), provider: "apple_mapkit", providerPlaceId: name, name: name, nameLocal: nil, address: nil,
              latitude: lat, longitude: lng, countryCode: cc)
    }

    /// 首爾＋廣島：平均中心在海上，要分成兩區。
    @Test func multiCountryTripGetsOneAreaPerRegion() {
        let seoul = [place("ORA", 37.45, 126.42, "KR"), place("明洞", 37.56, 126.98, "KR")]
        let hiroshima = [place("嚴島神社", 34.30, 132.32, "JP"), place("廣島機場", 34.44, 132.92, "JP"), place("尾道", 34.41, 133.21, "JP")]
        let areas = SearchAreas(places: seoul + hiroshima, timeZones: ["Asia/Seoul", "Asia/Tokyo"])
        #expect(areas.centers.count == 2)
        #expect(abs(areas.centers[0].latitude - 34.38) < 0.1)  // 地點多的區域在前
        #expect(areas.countries == ["KR", "JP"])

        let dayFirst = SearchAreas(places: seoul + hiroshima, preferred: seoul)
        #expect(abs(dayFirst.centers[0].latitude - 37.5) < 0.1)
        #expect(dayFirst.centers.count == 2)
    }

    @Test func timeZonesAddCountriesWithoutPlaces() {
        #expect(SearchAreas(places: [], timeZones: ["Asia/Tokyo"]).countries == ["JP"])
        #expect(SearchAreas(places: [], timeZones: ["Asia/Tokyo"]).centers.isEmpty)
    }
}
