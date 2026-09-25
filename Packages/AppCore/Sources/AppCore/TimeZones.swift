import Foundation

/// 跨國旅程的時區：每一天各自一個時區。
public enum TripTimeZones {
    /// 常用時區（旅遊目的地），選單顯示用。
    public static let common: [String] = [
        "Asia/Seoul", "Asia/Tokyo", "Asia/Taipei", "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Bangkok",
        "Asia/Singapore", "Asia/Ho_Chi_Minh", "Asia/Manila", "Europe/London", "Europe/Paris",
        "America/New_York", "America/Los_Angeles", "Australia/Sydney",
    ]

    /// 國家 → 主要時區（單一時區國家）。
    public static let byCountry: [String: String] = [
        "KR": "Asia/Seoul", "JP": "Asia/Tokyo", "TW": "Asia/Taipei", "HK": "Asia/Hong_Kong", "MO": "Asia/Macau",
        "CN": "Asia/Shanghai", "TH": "Asia/Bangkok", "SG": "Asia/Singapore", "VN": "Asia/Ho_Chi_Minh",
        "PH": "Asia/Manila", "MY": "Asia/Kuala_Lumpur", "GB": "Europe/London", "FR": "Europe/Paris",
        "DE": "Europe/Berlin", "IT": "Europe/Rome", "ES": "Europe/Madrid",
    ]

    static let cityNames: [String: String] = [
        "Asia/Seoul": "首爾", "Asia/Tokyo": "東京", "Asia/Taipei": "台北", "Asia/Hong_Kong": "香港", "Asia/Macau": "澳門",
        "Asia/Shanghai": "上海", "Asia/Bangkok": "曼谷", "Asia/Singapore": "新加坡", "Asia/Ho_Chi_Minh": "胡志明市",
        "Asia/Manila": "馬尼拉", "Asia/Kuala_Lumpur": "吉隆坡", "Europe/London": "倫敦", "Europe/Paris": "巴黎",
        "Europe/Berlin": "柏林", "Europe/Rome": "羅馬", "Europe/Madrid": "馬德里", "America/New_York": "紐約",
        "America/Los_Angeles": "洛杉磯", "Australia/Sydney": "雪梨",
    ]

    /// 「東京（UTC+9）」。
    public static func displayName(_ identifier: String, at date: Date = Date()) -> String {
        let city = cityNames[identifier] ?? identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
        guard let tz = TimeZone(identifier: identifier) else { return city }
        let seconds = tz.secondsFromGMT(for: date)
        let hours = seconds / 3600, minutes = abs(seconds % 3600) / 60
        let offset = minutes == 0 ? "UTC\(hours >= 0 ? "+" : "")\(hours)" : String(format: "UTC%+d:%02d", hours, minutes)
        return "\(city)（\(offset)）"
    }

    /// 依當天已確認地點的國家推測時區；多數地點所在的國家優先，無法判斷時為 nil。
    public static func suggested(for day: DayTimeline, places: [UUID: Place]) -> String? {
        let countries = day.stops.compactMap { $0.placeId.flatMap { places[$0]?.countryCode?.uppercased() } }
        guard let top = Dictionary(grouping: countries, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key else { return nil }
        return byCountry[top]
    }

    /// 當天時區與地點不一致時，回傳建議改成的時區。
    public static func mismatch(for day: DayTimeline, places: [UUID: Place]) -> String? {
        guard let suggestion = suggested(for: day, places: places),
              let current = TimeZone(identifier: day.day.timeZone), let proposed = TimeZone(identifier: suggestion),
              current.secondsFromGMT() != proposed.secondsFromGMT() || day.day.timeZone != suggestion
        else { return nil }
        // 同一個偏移量（例如首爾與東京都是 UTC+9）仍建議改成當地時區，名稱才正確。
        return suggestion
    }
}

extension TripRepository {
    /// 修改某一天的時區或交通方式（Owner／Editor）；會讓當天未確認的加入要求過期。
    /// 整趟旅程每天都改用同一種交通方式；回傳有改到的天數。
    @discardableResult
    public func setTripTransportMode(_ tripID: UUID, mode: TravelMode) async throws -> Int {
        struct Params: Encodable { let p_trip_id: UUID, p_transport_mode: TravelMode }
        do {
            return try await client.rpc("set_trip_transport_mode", params: Params(p_trip_id: tripID, p_transport_mode: mode)).execute().value
        } catch {
            throw BackendError.from(error)
        }
    }

    public func updateDay(_ dayID: UUID, timeZone: String? = nil, transportMode: TravelMode? = nil) async throws -> TripDay {
        struct Params: Encodable { let p_day_id: UUID, p_time_zone: String?, p_transport_mode: TravelMode? }
        do {
            return try await client.rpc("update_day", params: Params(p_day_id: dayID, p_time_zone: timeZone, p_transport_mode: transportMode)).execute().value
        } catch {
            throw BackendError.from(error)
        }
    }
}
