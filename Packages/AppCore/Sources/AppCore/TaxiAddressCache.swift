import CryptoKit
import Foundation

/// 只重用同店名、原始地址與座標的地址結果；任一目的地資料改變就不套用舊卡片。
public enum TaxiAddressCache {
    public struct Entry: Codable, Sendable { public let address: String; public let checkedAt: Date }
    static func key(_ card: TaxiCard) -> String {
        let parts = [card.name, card.address ?? "", card.countryCode ?? "", card.latitude.map(String.init(describing:)) ?? "", card.longitude.map(String.init(describing:)) ?? ""]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return "taxi-address-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func entry(for card: TaxiCard) -> Entry? {
        UserDefaults.standard.data(forKey: key(card)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
    }
    public static func save(address: String, for card: TaxiCard) {
        if let data = try? JSONEncoder().encode(Entry(address: address, checkedAt: Date())) {
            UserDefaults.standard.set(data, forKey: key(card))
        }
    }
}
