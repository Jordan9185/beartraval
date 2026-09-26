import Foundation
import ImageIO
import Supabase
import UniformTypeIdentifiers

/// AI 從分享的貼文（圖片＋文字）辨識出的商品草稿；使用者挑選、修改後才加入購物清單。
/// 只說「貼文裡有這個商品」，不代表哪裡有賣或有庫存（規格規則 6）。
public struct ExtractedProduct: Decodable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var brand: String?
    public var variant: String?
    public var searchQuery: String?
    /// 分享內容提到的店名線索，並非販售或庫存證據。
    public var storeHint: String?
    public var storeEvidence: String?
    /// 引用的貼文文字，或 "image"。
    public var evidence: String
    public var confidence: String

    public init(name: String, brand: String? = nil, variant: String? = nil, searchQuery: String? = nil,
                storeHint: String? = nil, storeEvidence: String? = nil,
                evidence: String = "image", confidence: String = "high") {
        self.name = name
        self.brand = brand
        self.variant = variant
        self.searchQuery = searchQuery
        self.storeHint = storeHint
        self.storeEvidence = storeEvidence
        self.evidence = evidence
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case name, brand, variant, evidence, confidence
        case searchQuery = "search_query"
        case storeHint = "store_hint"
        case storeEvidence = "store_evidence"
    }

    /// 購物清單上的名稱：品牌沒寫在名稱裡時補在前面，規格（色號、尺寸）放後面。
    public var listName: String {
        var parts: [String] = []
        if let brand, !name.localizedCaseInsensitiveContains(brand) { parts.append(brand) }
        parts.append(name)
        if let variant, !name.localizedCaseInsensitiveContains(variant) { parts.append(variant) }
        return parts.joined(separator: " ")
    }
}

public struct ProductExtraction: Sendable, Equatable {
    public var products: [ExtractedProduct]
    public var warnings: [String]

    public init(products: [ExtractedProduct], warnings: [String]) {
        self.products = products
        self.warnings = warnings
    }
}

public enum ProductExtractionError: Error, Equatable {
    case failed(reason: String)

    public var userMessage: String {
        switch self {
        case .failed("missing_api_key"): "AI 服務尚未設定。"
        case .failed("rate_limited"): "AI 辨識次數已達上限，請稍後再試，或直接手動輸入。"
        case .failed(let reason): "辨識失敗（\(reason)），可以直接手動輸入。"
        }
    }
}

extension TripRepository {
    public func extractProducts(tripID: UUID, text: String, url: String?, imageJPEG: Data?) async throws -> ProductExtraction {
        struct Body: Encodable { let trip_id: UUID, text: String, url: String?, image_base64: String? }
        struct Response: Decodable {
            let status: String, products: [ExtractedProduct]?, warnings: [String]?, reason: String?
        }
        let r: Response
        do {
            r = try await client.functions.invoke("extract-products", options: FunctionInvokeOptions(
                body: Body(trip_id: tripID, text: text, url: url, image_base64: imageJPEG?.base64EncodedString())))
        } catch {
            throw BackendError.from(error)
        }
        guard r.status == "extracted" else { throw ProductExtractionError.failed(reason: r.reason ?? "unknown") }
        return ProductExtraction(products: r.products ?? [], warnings: r.warnings ?? [])
    }

    public func setShoppingImage(tripID: UUID, itemID: UUID, jpeg: Data) async throws {
        // 路徑以 trip 為第一層，Storage 規則依此判斷成員權限。
        let path = "\(tripID.uuidString.lowercased())/\(itemID.uuidString.lowercased())-\(UUID().uuidString.prefix(8).lowercased()).jpg"
        struct Params: Encodable { let p_item_id: UUID, p_image_path: String? }
        do {
            _ = try await client.storage.from(ShoppingImages.bucket)
                .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg"))
            try await client.rpc("set_shopping_image", params: Params(p_item_id: itemID, p_image_path: path)).execute()
        } catch {
            throw BackendError.from(error)
        }
    }

    public func shoppingImageURL(path: String) async -> URL? {
        // 簽名網址等於通行證，快取以帳號區分，換帳號後不會拿到前一個帳號的網址。
        guard let user = currentUserID else { return nil }
        let key = "\(user.uuidString)|\(path)"
        if let cached = await ShoppingImages.cache.url(for: key) { return cached }
        guard let url = try? await client.storage.from(ShoppingImages.bucket)
            .createSignedURL(path: path, expiresIn: ShoppingImages.signedSeconds, download: String?.none) else { return nil }
        await ShoppingImages.cache.store(url, for: key)
        return url
    }
}

public enum ShoppingImages {
    public static let bucket = "shopping-images"
    static let signedSeconds = 3600
    static let cache = SignedURLCache(lifetime: TimeInterval(signedSeconds - 300))
}

/// 簽名網址快取，避免清單每次捲動都重新簽。
actor SignedURLCache {
    private let lifetime: TimeInterval
    private var entries: [String: (url: URL, expires: Date)] = [:]

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    func url(for path: String) -> URL? {
        guard let entry = entries[path], entry.expires > Date() else { return nil }
        return entry.url
    }

    func store(_ url: URL, for path: String) {
        entries[path] = (url, Date().addingTimeInterval(lifetime))
    }
}

/// 上傳前把照片縮到長邊 1024 px 的 JPEG（Share Extension 記憶體有限，也省流量與 AI 用量）。
public enum ImageDownscale {
    public static let maxPixel = 1024

    public static func jpeg(from data: Data, maxPixel: Int = maxPixel) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpeg(from: source, maxPixel: maxPixel)
    }

    public static func jpeg(fileURL: URL, maxPixel: Int = maxPixel) -> Data? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return jpeg(from: source, maxPixel: maxPixel)
    }

    static func jpeg(from source: CGImageSource, maxPixel: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// 到社群與搜尋引擎找這個商品（別人的開箱、在哪買）。只開網頁，不讀回任何資料。
public enum ProductSearchLinks {
    public struct Link: Hashable, Sendable {
        public var title: String
        public var url: URL
    }

    public static func links(for query: String) -> [Link] {
        func make(_ title: String, _ base: String, _ key: String) -> Link? {
            var components = URLComponents(string: base)
            components?.queryItems = [URLQueryItem(name: key, value: query)]
            return components?.url.map { Link(title: title, url: $0) }
        }
        return [
            make("Instagram", "https://www.instagram.com/explore/search/keyword/", "q"),
            make("Threads", "https://www.threads.com/search", "q"),
            make("小紅書", "https://www.xiaohongshu.com/search_result", "keyword"),
            make("Google", "https://www.google.com/search", "q"),
        ].compactMap { $0 }
    }
}
