#if DEBUG
import AppCore
import Foundation
import SwiftUI

/// XCUITest 用的匯入情境（不需登入、不連後端）。App 以 `-UITestImport <scenario>` 啟動時使用。
///
/// - `ambiguous`：含兩個可能分店的「XXX Shoes」（AC-01）
/// - `failThenSucceed`：第一次解析失敗，重試後成功（原文不丟）
public struct ImportUITestRoot: View {
    let scenario: String
    @State private var created: Trip?

    public init(scenario: String) {
        self.scenario = scenario
    }

    public var body: some View {
        NavigationStack {
            if let created {
                ContentUnavailableView("已建立 \(created.name)", systemImage: "checkmark.circle")
                    .accessibilityIdentifier("tripCreated")
            } else {
                ImportFlowView(session: FakeImportService.session, service: FakeImportService(failFirst: scenario == "failThenSucceed"),
                               placeSearch: FakePlaceSearch()) { created = $0 }
            }
        }
    }
}

final class FakeImportService: ImportService, @unchecked Sendable {
    static let rawText = "Day 1\n10:00 광장시장\nXXX Shoes 買鞋\n19:00 晚餐訂位 Some Restaurant"
    static let session = ImportSession(id: UUID(), tripName: "UI Test Seoul", startDate: "2026-10-01", endDate: "2026-10-02",
                                       timeZone: "Asia/Seoul", rawText: rawText, parseStatus: .pending)

    private let lock = NSLock()
    private var remainingFailures: Int

    init(failFirst: Bool) {
        remainingFailures = failFirst ? 1 : 0
    }

    func createImport(tripName: String, startDate: String, endDate: String, timeZone: String, rawText: String) async throws -> ImportSession {
        Self.session
    }

    func updateText(importID: UUID, rawText: String) async throws -> ImportSession {
        var s = Self.session
        s.rawText = rawText
        return s
    }

    func parse(importID: UUID) async throws -> ImportSession {
        try await Task.sleep(for: .milliseconds(300))
        var s = Self.session
        let fail = lock.withLock { () -> Bool in
            defer { remainingFailures = max(0, remainingFailures - 1) }
            return remainingFailures > 0
        }
        if fail {
            s.parseStatus = .failed
            s.parseError = "provider_error"
            return s
        }
        s.parseStatus = .parsed
        s.parseResult = .init(draft: ParseDraft(days: [
            .init(date: "2026-10-01", dayLabel: "Day 1", stops: [
                ParsedStop(sourceExcerpt: "10:00 광장시장", placeName: "광장시장", category: "eat", startTime: "10:00"),
                ParsedStop(sourceExcerpt: "XXX Shoes 買鞋", placeName: "XXX Shoes", category: "shop", needsConfirmation: [.ambiguousBranch]),
                ParsedStop(sourceExcerpt: "19:00 晚餐訂位 Some Restaurant", placeName: "Some Restaurant", category: "eat",
                           startTime: "19:00", fixedSuspected: true, fixedReason: "訂位"),
            ]),
        ], cityCandidates: ["Seoul"], warnings: []))
        return s
    }

    func registerPlace(_ draft: PlaceDraft) async throws -> Place {
        Place(id: UUID(), provider: draft.provider.rawValue, providerPlaceId: draft.providerPlaceId, name: draft.name,
              nameLocal: nil, address: draft.address, latitude: draft.latitude, longitude: draft.longitude, countryCode: draft.countryCode)
    }

    func commit(importID: UUID, days: [ImportDayCommit]) async throws -> Trip {
        Trip(id: UUID(), name: Self.session.tripName, startDate: "2026-10-01", endDate: "2026-10-02", timeZone: "Asia/Seoul", revision: 1)
    }
}

struct FakePlaceSearch: PlaceSearching {
    func search(_ query: String, near city: String?, limit: Int) async -> [PlaceOption] {
        func option(_ name: String, _ lat: Double) -> PlaceOption {
            PlaceOption(draft: PlaceDraft(providerPlaceId: name, name: name, address: "서울", latitude: lat, longitude: 127, countryCode: "KR"))
        }
        switch query {
        case "XXX Shoes": return [option("XXX Shoes 명동점", 37.56), option("XXX Shoes 성수점", 37.54)]
        case "광장시장": return [option("광장시장", 37.57)]
        case "Some Restaurant": return [option("Some Restaurant", 37.55)]
        default: return []
        }
    }
}
#endif
