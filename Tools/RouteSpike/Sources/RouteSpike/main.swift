import Foundation
import MapKit

// S1 路線／POI 實測（issue #1）。
//
// 用法（在 repo 根目錄）：
//   swift run --package-path Tools/RouteSpike RouteSpike routes
//   swift run --package-path Tools/RouteSpike RouteSpike poi [locale]
// 輸入：docs/research/data/od-pairs.csv、poi-queries.csv
// 輸出：docs/research/data/route-results.csv、poi-results[-locale].csv（覆寫）

let dataDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "docs/research/data")
/// MKDirections／MKLocalSearch 有節流（約每分鐘 50 次），每次請求間隔。
let requestInterval: Duration = .milliseconds(1300)

struct CSV {
    static func read(_ name: String) throws -> [[String: String]] {
        let text = try String(contentsOf: dataDir.appending(path: name), encoding: .utf8)
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let header = lines.removeFirst().components(separatedBy: ",")
        return lines.map { line in
            let fields = line.components(separatedBy: ",")
            return Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0 < fields.count ? fields[$0] : "") })
        }
    }

    static func escape(_ value: String) -> String {
        value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : value
    }

    static func write(_ name: String, header: [String], rows: [[String]]) throws {
        let body = ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
        try body.write(to: dataDir.appending(path: name), atomically: true, encoding: .utf8)
    }
}

func location(_ row: [String: String], _ prefix: String) -> CLLocation {
    CLLocation(latitude: Double(row["\(prefix)_lat"]!)!, longitude: Double(row["\(prefix)_lng"]!)!)
}

func describe(_ error: any Error) -> (domain: String, code: String, geo: String, message: String) {
    let ns = error as NSError
    let geo = [ns.userInfo["MKErrorGEOError"].map { "\($0)" }, (ns.userInfo["MKErrorGEOErrorUserInfo"] as? [String: Any])?["NSDebugDescription"].map { "\($0)" }]
        .compactMap { $0 }.joined(separator: " ")
    return (ns.domain, "\(ns.code)", geo, ns.localizedDescription)
}

func runRoutes() async throws {
    let pairs = try CSV.read("od-pairs.csv")
    let modes: [(String, MKDirectionsTransportType)] = [("walking", .walking), ("transit", .transit), ("driving", .automobile)]
    let runAt = ISO8601DateFormatter().string(from: Date())
    var rows: [[String]] = []
    for pair in pairs {
        let from = location(pair, "from"), to = location(pair, "to")
        let straight = Int(from.distance(from: to))
        for (modeName, transport) in modes {
            let request = MKDirections.Request()
            request.source = MKMapItem(location: from, address: nil)
            request.destination = MKMapItem(location: to, address: nil)
            request.transportType = transport
            request.departureDate = Date()
            let start = ContinuousClock.now
            var row = [runAt, pair["id"]!, pair["city"]!, pair["detour_case"]!, modeName, pair["from_name"]!, pair["to_name"]!, "\(straight)"]
            do {
                let eta = try await MKDirections(request: request).calculateETA()
                let latency = (ContinuousClock.now - start).components
                row += ["ok", String(format: "%.1f", eta.expectedTravelTime / 60), "\(Int(eta.distance))",
                        "\(latency.seconds * 1000 + latency.attoseconds / 1_000_000_000_000_000)", "", "", "", ""]
            } catch {
                let latency = (ContinuousClock.now - start).components
                let e = describe(error)
                row += ["unavailable", "", "", "\(latency.seconds * 1000 + latency.attoseconds / 1_000_000_000_000_000)", e.domain, e.code, e.geo, e.message]
            }
            print(row.joined(separator: " | "))
            rows.append(row)
            try await Task.sleep(for: requestInterval)
        }
    }
    try CSV.write("route-results.csv", header: [
        "run_at", "od_id", "city", "detour_case", "mode", "from", "to", "straight_m",
        "status", "apple_minutes", "apple_distance_m", "latency_ms", "error_domain", "error_code", "geo_error", "error_message",
    ], rows: rows)
}

let regions: [String: MKCoordinateRegion] = [
    "seoul": MKCoordinateRegion(center: .init(latitude: 37.5540, longitude: 126.9900), latitudinalMeters: 30_000, longitudinalMeters: 30_000),
    "hiroshima": MKCoordinateRegion(center: .init(latitude: 34.3900, longitude: 132.4500), latitudinalMeters: 30_000, longitudinalMeters: 30_000),
]

func runPOI(localeTag: String?) async throws {
    let queries = try CSV.read("poi-queries.csv")
    var rows: [[String]] = []
    for query in queries {
        let region = regions[query["city"]!]!
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query["query"]!
        request.region = region
        request.resultTypes = [.pointOfInterest, .address]
        let start = ContinuousClock.now
        var row = [query["id"]!, query["city"]!, query["lang"]!, query["query"]!, query["expect"]!]
        do {
            let items = try await MKLocalSearch(request: request).start().mapItems
            let latency = (ContinuousClock.now - start).components
            let center = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
            let top = items.first
            row += [
                "\(items.count)",
                top?.name ?? "",
                top?.address?.fullAddress.replacingOccurrences(of: "\n", with: " ") ?? "",
                top.map { String(format: "%.5f", $0.location.coordinate.latitude) } ?? "",
                top.map { String(format: "%.5f", $0.location.coordinate.longitude) } ?? "",
                top.map { "\(Int($0.location.distance(from: center)))" } ?? "",
                items.prefix(5).compactMap(\.name).joined(separator: " / "),
                "\(latency.seconds * 1000 + latency.attoseconds / 1_000_000_000_000_000)",
                "",
            ]
        } catch {
            let e = describe(error)
            row += ["0", "", "", "", "", "", "", "", "\(e.domain) \(e.code) \(e.geo)"]
        }
        print(row.joined(separator: " | "))
        rows.append(row)
        try await Task.sleep(for: requestInterval)
    }
    try CSV.write(localeTag.map { "poi-results-\($0).csv" } ?? "poi-results.csv", header: [
        "id", "city", "lang", "query", "expect", "result_count", "top_name", "top_address", "top_lat", "top_lng",
        "top_distance_from_center_m", "top5_names", "latency_ms", "error",
    ], rows: rows)
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "routes":
    try await runRoutes()
case "poi":
    // 第二個參數只用來命名輸出檔；語系需用 -AppleLanguages 啟動參數切換。
    try await runPOI(localeTag: arguments.dropFirst().first.flatMap { $0.hasPrefix("-") ? nil : $0 })
default:
    print("usage: RouteSpike routes | poi [tag] [-AppleLanguages (ko)]")
}
