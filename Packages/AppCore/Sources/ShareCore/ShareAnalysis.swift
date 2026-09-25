import AppCore
import Foundation
import UniformTypeIdentifiers

/// 分享內容中可用的部分（從 NSItemProvider 載入後整理）。
public struct ShareContent: Codable, Equatable, Sendable {
    public var urls: [URL]
    public var texts: [String]
    /// 主機 App 給的標題（例如 Safari 的頁面標題）。
    public var title: String?
    public var hasImage: Bool
    /// 第一張圖的縮圖（有拿到時）；購物清單附圖、AI 辨識商品用。
    public var imageJPEG: Data?

    public init(urls: [URL] = [], texts: [String] = [], title: String? = nil, hasImage: Bool = false, imageJPEG: Data? = nil) {
        self.urls = urls
        self.texts = texts
        self.title = title
        self.hasImage = hasImage
        self.imageJPEG = imageJPEG
    }

    /// 由 Payload Inspector 的紀錄整理。
    public init(record: PayloadRecord) {
        var urls: [URL] = [], texts: [String] = [], hasImage = false, title: String?, imageJPEG: Data?
        for item in record.items {
            if let t = item.attributedContentText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { texts.append(t) }
            if title == nil, let t = item.attributedTitle, !t.isEmpty { title = t }
            for attachment in item.attachments {
                if attachment.registeredTypeIdentifiers.contains(where: { UTType($0)?.conforms(to: .image) == true }) { hasImage = true }
                for load in attachment.loads {
                    if imageJPEG == nil, let jpeg = load.imageJPEG { imageJPEG = jpeg }
                    guard let preview = load.preview else { continue }
                    switch load.kind {
                    case .url: if let url = URL(string: preview), url.scheme?.lowercased().hasPrefix("http") == true, !urls.contains(url) { urls.append(url) }
                    case .text: texts.append(preview)
                    default: break
                    }
                }
            }
        }
        // 純文字中夾帶的網址也算。
        for text in texts {
            for url in ShareAnalysis.urls(in: text) where !urls.contains(url) { urls.append(url) }
        }
        self.init(urls: urls, texts: texts, title: title, hasImage: hasImage, imageJPEG: imageJPEG)
    }
}

/// 地圖連結裡能直接讀到的地點線索。
public struct MapHint: Equatable, Sendable {
    public var name: String?
    public var coordinate: Coordinate?
}

public struct ShareAnalysis: Equatable, Sendable {
    public enum Platform: String, Sendable {
        case threads, instagram, googleMaps, appleMaps, naverMap, kakaoMap, web, none
    }

    /// AC-04：明列缺少的資訊，不假裝辨識成功。
    public enum Missing: Equatable, Sendable {
        /// Threads／IG 只給了網址，拿不到貼文內容。
        case noPostContent
        /// 沒有可用來搜尋的店名。
        case noPlaceName
        /// 短網址需要展開才知道位置。
        case shortLinkUnresolved
    }

    public var platform: Platform
    public var sourceURL: URL?
    public var canonicalURL: String?
    public var mapHint: MapHint?
    /// 預填的搜尋字；使用者可修改。
    public var suggestedQuery: String?
    public var excerpt: String?
    public var missing: [Missing]

    public init(_ content: ShareContent) {
        let url = content.urls.first ?? content.texts.lazy.flatMap(Self.urls).first
        sourceURL = url
        canonicalURL = url.map(SourceURL.canonical)
        platform = url.map(Self.platform) ?? .none
        mapHint = url.flatMap(MapLink.hint)
        let text = content.texts.first { Self.firstMeaningfulLine($0) != nil }
        excerpt = text.map { String($0.prefix(300)) }

        var missing: [Missing] = []
        let isSocial = platform == .threads || platform == .instagram
        if isSocial && text == nil { missing.append(.noPostContent) }
        if let url, MapLink.isShortLink(url), mapHint == nil { missing.append(.shortLinkUnresolved) }

        suggestedQuery = mapHint?.name ?? text.flatMap(Self.firstMeaningfulLine) ?? content.title.flatMap(Self.usableTitle)
        if suggestedQuery == nil && mapHint?.coordinate == nil { missing.append(.noPlaceName) }
        self.missing = missing
    }

    static func platform(_ url: URL) -> Platform {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("threads.net") || host.hasSuffix("threads.com") { return .threads }
        if host.hasSuffix("instagram.com") { return .instagram }
        if host == "maps.apple.com" || host == "maps.apple" { return .appleMaps }
        if host.contains("google.") && url.path.hasPrefix("/maps") || host.hasPrefix("maps.google.") || host == "maps.app.goo.gl" || host == "goo.gl" { return .googleMaps }
        if host.hasSuffix("map.naver.com") || host == "naver.me" { return .naverMap }
        if host.hasSuffix("map.kakao.com") || host == "kko.to" { return .kakaoMap }
        return .web
    }

    public static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            .filter { $0.scheme?.lowercased().hasPrefix("http") == true }
    }

    /// 第一行去掉網址後、非 hashtag／帳號的文字，最多 60 字。
    static func firstMeaningfulLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { line -> String in
                var s = String(line)
                for url in urls(in: s) { s = s.replacingOccurrences(of: url.absoluteString, with: "") }
                return s.trimmingCharacters(in: .whitespaces)
            }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("@") }
            .map { String($0.prefix(60)) }
    }

    /// 平台名稱本身（「Instagram」「Threads」）不是店名。
    static func usableTitle(_ title: String) -> String? {
        let generic = ["instagram", "threads", "google maps", "apple maps", "naver map", "kakaomap"]
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || generic.contains(t.lowercased()) ? nil : String(t.prefix(60))
    }
}

public enum SourceURL {
    static let trackingParameters: Set<String> = ["igsh", "igshid", "fbclid", "gclid", "si", "ref", "ref_src", "xmt", "slof", "img_index"]

    /// 重複分享去重用（`canonical_url`）：小寫網域、去掉 fragment、追蹤參數、結尾斜線；
    /// Threads／IG 貼文網址的查詢字串全部去掉。
    public static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        var host = components.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host == "threads.net" { host = "threads.com" }
        components.host = host
        components.fragment = nil
        if host.hasSuffix("instagram.com") || host.hasSuffix("threads.com") {
            components.queryItems = nil
        } else if let items = components.queryItems {
            let kept = items.filter { !$0.name.lowercased().hasPrefix("utm_") && !trackingParameters.contains($0.name.lowercased()) }
                .sorted { $0.name < $1.name }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        if components.path.count > 1 && components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? url.absoluteString
    }
}

/// Google／Apple／Naver／Kakao 地圖連結的座標與名稱解析（S2 退路 4）。
public enum MapLink {
    public static func isShortLink(_ url: URL) -> Bool {
        ["maps.app.goo.gl", "goo.gl", "naver.me", "kko.to"].contains(url.host?.lowercased() ?? "")
    }

    public static func hint(_ url: URL) -> MapHint? {
        let host = url.host?.lowercased() ?? ""
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })

        if host == "maps.apple.com" || host == "maps.apple" {
            let coord = (query["coordinate"] ?? query["ll"] ?? query["sll"]).flatMap(pair)
            let name = query["name"] ?? query["q"]
            return coord == nil && name == nil ? nil : MapHint(name: name.flatMap(nonCoordinateName), coordinate: coord)
        }
        if host.contains("google.") || host.hasPrefix("maps.google.") {
            // /maps/place/<Name>/@lat,lng,zoom
            var name: String?, coord: Coordinate?
            let parts = url.path.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(of: "place"), i + 1 < parts.count {
                name = parts[i + 1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            }
            if let at = parts.first(where: { $0.hasPrefix("@") }) { coord = pair(String(at.dropFirst())) }
            if let q = query["q"] ?? query["query"] {
                if let c = pair(q) { coord = coord ?? c } else { name = name ?? q }
            }
            return name == nil && coord == nil ? nil : MapHint(name: name, coordinate: coord)
        }
        if host.hasSuffix("map.kakao.com") {
            // /link/map/<Name>,lat,lng 或 /link/to/<Name>,lat,lng
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count >= 3, parts[0] == "link", let last = parts.last?.removingPercentEncoding {
                let fields = last.split(separator: ",").map(String.init)
                if fields.count >= 3, let lat = Double(fields[fields.count - 2]), let lng = Double(fields[fields.count - 1]) {
                    return MapHint(name: fields.dropLast(2).joined(separator: ","), coordinate: Coordinate(latitude: lat, longitude: lng))
                }
            }
            return nil
        }
        if host.hasSuffix("map.naver.com") {
            if let lat = query["lat"].flatMap(Double.init), let lng = query["lng"].flatMap(Double.init) {
                return MapHint(name: query["title"] ?? query["name"], coordinate: Coordinate(latitude: lat, longitude: lng))
            }
            return nil
        }
        return nil
    }

    static func pair(_ text: String) -> Coordinate? {
        let fields = text.split(separator: ",").prefix(2).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard fields.count == 2, (-90...90).contains(fields[0]), (-180...180).contains(fields[1]) else { return nil }
        return Coordinate(latitude: fields[0], longitude: fields[1])
    }

    static func nonCoordinateName(_ text: String) -> String? {
        pair(text) == nil ? text : nil
    }

    /// 展開短網址（只跟隨轉址，不讀內容）；失敗時回 nil。
    public static func expand(_ url: URL, timeout: TimeInterval = 5) async -> URL? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return response.url == url ? nil : response.url
    }
}
