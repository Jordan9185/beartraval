import Foundation
import Testing
@testable import AppCore

struct BackendTests {
    @Test(arguments: [
        ("PT401", BackendError.unauthenticated),
        ("PT403", .forbidden),
        ("PT404", .notFound),
        ("PT409", .conflict("INVITE_EXPIRED")),
        ("PT410", .gone("INVITE_EXPIRED")),
        ("PT422", .invalid("INVITE_EXPIRED")),
        ("42501", .forbidden),
        ("XX000", .other("INVITE_EXPIRED")),
    ])
    func mapsSQLStateToError(code: String, expected: BackendError) {
        #expect(BackendError(code: code, message: "INVITE_EXPIRED") == expected)
    }

    @Test func staleRevisionIsDistinctFromOtherConflicts() {
        #expect(BackendError(code: "PT409", message: "STALE_REVISION") == .staleRevision)
        #expect(BackendError(code: "PT409", message: "DUPLICATE_SAVED") == .conflict("DUPLICATE_SAVED"))
    }

    @Test func localDateUsesTripTimeZone() {
        // 2026-09-30 16:30 UTC = 首爾 10/01 01:30
        let date = Date(timeIntervalSince1970: 1_790_785_800)
        #expect(LocalDate.string(from: date, timeZone: TimeZone(identifier: "Asia/Seoul")!) == "2026-10-01")
        #expect(LocalDate.string(from: date, timeZone: TimeZone(identifier: "UTC")!) == "2026-09-30")
    }

    @Test func tripDecodesFromPostgRESTRow() throws {
        let json = #"{"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","name":"首爾","start_date":"2026-10-01","end_date":"2026-10-04","time_zone":"Asia/Seoul","primary_city":null,"owner_id":"6f9619ff-8b86-d011-b42d-00c04fc964fe","revision":0,"created_at":"2026-09-24T00:00:00Z","updated_at":"2026-09-24T00:00:00Z"}"#
        let trip = try JSONDecoder().decode(Trip.self, from: Data(json.utf8))
        #expect(trip.name == "首爾")
        #expect(trip.startDate == "2026-10-01")
        #expect(trip.timeZone == "Asia/Seoul")
    }
}
