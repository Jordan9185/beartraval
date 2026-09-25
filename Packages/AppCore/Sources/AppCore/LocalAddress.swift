import Contacts
import CoreLocation
import Foundation
import MapKit

/// 當地文字的地址（給計程車司機看、外開當地地圖）。
/// Apple 依手機語言回傳地址：繁中手機拿到的是「南韓首爾特別市明洞명동10길」這種中韓混寫，
/// 司機看不懂，所以用當地語言再反查一次。
public enum LocalAddress {
    /// 需要當地文字地址的國家與查詢語系。
    public static func locale(for countryCode: String?) -> Locale? {
        switch countryCode?.uppercased() {
        case "KR": Locale(identifier: "ko_KR")
        case "JP": Locale(identifier: "ja_JP")
        default: nil
        }
    }

    /// 這個地址是不是已經用當地文字寫的。
    /// 韓國：有韓文、沒有漢字（韓國地址幾乎不寫漢字）。日本：沒有中文才有的寫法（區、縣…）。
    public static func isLocal(_ address: String, countryCode: String?) -> Bool {
        switch countryCode?.uppercased() {
        case "KR": PlaceNaming.hasHangul(address) && !PlaceNaming.hasHan(address)
        case "JP": !["區", "縣", "臺", "灣", "號"].contains(where: address.contains) && !address.hasPrefix("日本")
        default: true
        }
    }

    /// 地址已是當地文字就直接用；否則用當地語言反查座標。查不到（離線、逾時）回 nil。
    public static func lookup(latitude: Double, longitude: Double, countryCode: String?, knownAddress: String?) async -> String? {
        guard let locale = locale(for: countryCode) else { return nil }
        if let knownAddress, isLocal(knownAddress, countryCode: countryCode) { return knownAddress }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let found = await withTaskGroup(of: String?.self) { group in
            group.addTask { await reverseGeocode(location, locale: locale) }
            // 存檔不該因為反查卡住太久。
            group.addTask { try? await Task.sleep(for: .seconds(4)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let found = found.map({ stripCountry($0) }), !found.isEmpty, isLocal(found, countryCode: countryCode) else { return nil }
        return found
    }

    static func reverseGeocode(_ location: CLLocation, locale: Locale) async -> String? {
        if #available(iOS 26, macOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            request.preferredLocale = locale
            return try? await request.mapItems.first?.address?.fullAddress.replacingOccurrences(of: "\n", with: " ")
        }
        guard let postal = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: locale).first?.postalAddress else { return nil }
        return CNPostalAddressFormatter.string(from: postal, style: .mailingAddress).replacingOccurrences(of: "\n", with: " ")
    }

    /// 司機不需要看到國名。
    static func stripCountry(_ address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespaces)
        for prefix in ["대한민국", "日本、", "日本"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
