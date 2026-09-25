import Foundation
import Supabase
import Testing
@testable import AppCore

/// 商品照片存取權限（本機 Supabase；設定方式見 ItineraryIntegrationTests）。
@Suite(.enabled(if: IntegrationEnv.config != nil))
struct ShoppingImageIntegrationTests {
    @Test func onlyTripMembersCanReadOrUpload() async throws {
        let owner = try await IntegrationEnv.signedInRepository()
        let trip = try await owner.createTrip(name: "Images", startDate: "2026-10-01", endDate: "2026-10-01", timeZone: "Asia/Seoul")
        let item = try await owner.addShoppingItem(tripID: trip.id, name: "ReFa", note: nil, url: nil, clientOpID: nil)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 64) + Data([0xFF, 0xD9])

        try await owner.setShoppingImage(tripID: trip.id, itemID: item.id, jpeg: jpeg)
        let path = try #require(try await owner.shoppingEntries(of: trip.id).first?.item.imagePath)
        #expect(path.hasPrefix(trip.id.uuidString.lowercased() + "/"))
        let url = try #require(await owner.shoppingImageURL(path: path))
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        // 非成員：簽不到網址，也不能上傳到這個旅程的資料夾。
        let outsider = try await IntegrationEnv.signedInRepository()
        #expect(await outsider.shoppingImageURL(path: path) == nil)
        await #expect(throws: (any Error).self) {
            _ = try await outsider.client.storage.from(ShoppingImages.bucket)
                .upload("\(trip.id.uuidString.lowercased())/planted.jpg", data: jpeg, options: FileOptions(contentType: "image/jpeg"))
        }
    }
}
