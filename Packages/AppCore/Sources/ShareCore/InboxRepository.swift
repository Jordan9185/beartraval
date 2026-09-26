import AppCore
import CryptoKit
import Foundation
import Supabase

public struct InboxRecord: Decodable, Identifiable, Sendable {
    public var id: UUID
    public var sourceURL: String?
    public var title: String?
    public var rawText: String
    public var publicText: String?
    public var resolvedSourceURL: String?
    public var unavailableCount: Int
    public var status: String
    public var contentKind: String?
    public var errorCode: String?
    public var lastSharedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, status
        case sourceURL = "source_url"
        case rawText = "raw_text"
        case publicText = "public_text"
        case resolvedSourceURL = "resolved_source_url"
        case unavailableCount = "unavailable_count"
        case contentKind = "content_kind"
        case errorCode = "error_code"
        case lastSharedAt = "last_shared_at"
    }
}

public struct InboxItemRecord: Decodable, Identifiable, Sendable {
    public var id: UUID
    public var captureID: UUID
    public var kind: String
    public var displayName: String
    public var sourceSpan: String
    public var confidence: String
    public var originType: String
    public var dayIndex: Int?
    public var resolutionStatus: String
    public var placeID: UUID?
    public var storeHint: String?
    public var storeEvidence: String?
    /// 網路來源支持的候選；不等於已確認地圖座標。
    public var discoveryCandidates: [DiscoveredPlace]?
    public var discoveryCheckedAt: String?
    public var archived: Bool
    public var revision: Int

    enum CodingKeys: String, CodingKey {
        case id, kind, confidence, archived, revision
        case captureID = "capture_id"
        case displayName = "display_name"
        case sourceSpan = "source_span"
        case originType = "origin_type"
        case dayIndex = "day_index"
        case resolutionStatus = "resolution_status"
        case placeID = "place_id"
        case storeHint = "store_hint"
        case storeEvidence = "store_evidence"
        case discoveryCandidates = "discovery_candidates"
        case discoveryCheckedAt = "discovery_checked_at"
    }
}

public struct InboxTemplateStop: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var label: String
    public var sourceSpan: String
    public var originType: String

    public init(id: UUID = UUID(), label: String, sourceSpan: String, originType: String) {
        self.id = id; self.label = label; self.sourceSpan = sourceSpan; self.originType = originType
    }

    enum CodingKeys: String, CodingKey {
        case label
        case sourceSpan = "source_span"
        case originType = "origin_type"
    }
}

public struct InboxTemplateDay: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var dayIndex: Int?
    public var sourceSpan: String
    public var stops: [InboxTemplateStop]

    public init(id: UUID = UUID(), dayIndex: Int?, sourceSpan: String, stops: [InboxTemplateStop]) {
        self.id = id; self.dayIndex = dayIndex; self.sourceSpan = sourceSpan; self.stops = stops
    }

    enum CodingKeys: String, CodingKey {
        case stops
        case dayIndex = "day_index"
        case sourceSpan = "source_span"
    }
}

public struct InboxTemplateDraft: Codable, Equatable, Sendable {
    public var days: [InboxTemplateDay]
}

public struct InboxTemplateRecord: Decodable, Identifiable, Sendable {
    public var id: UUID
    public var captureID: UUID
    public var title: String
    public var draft: InboxTemplateDraft
    public var revision: Int

    enum CodingKeys: String, CodingKey {
        case id, title, draft, revision
        case captureID = "capture_id"
    }
}

public enum InboxSyncError: Error {
    case accountConfirmationRequired
    case wrongAccount
    case uploadUnavailable
}

public struct DiscoveredPlace: Decodable, Identifiable, Sendable {
    public var name: String
    public var koreanName: String?
    public var addressLocal: String?
    public var searchQuery: String
    public var reason: String
    public var sourceURL: String

    public var id: String { name + "|" + sourceURL }

    enum CodingKeys: String, CodingKey {
        case name, reason
        case koreanName = "korean_name"
        case addressLocal = "address_local"
        case searchQuery = "search_query"
        case sourceURL = "source_url"
    }
}

public enum PlaceDiscoveryError: Error {
    case unavailable(String)

    public var userMessage: String {
        switch self {
        case .unavailable("rate_limited"): "AI 查找次數暫時已達上限，請稍後再試。"
        case .unavailable("search_unavailable"): "即時網路查找尚未啟用；可先用店名搜尋地圖。"
        default: "暫時無法查找店家資料，請稍後重試。"
        }
    }
}

/// 同一件商品在辨識頁與購物詳情間切換時，沿用短時間內的店家結果，避免重複消耗 AI 額度。
private actor StoreDiscoveryCache {
    static let shared = StoreDiscoveryCache()
    private var entries: [String: (Date, [DiscoveredPlace])] = [:]

    func get(_ key: String) -> [DiscoveredPlace]? {
        guard let (date, candidates) = entries[key], Date().timeIntervalSince(date) < 3600 else { return nil }
        return candidates
    }

    func put(_ candidates: [DiscoveredPlace], for key: String) {
        entries[key] = (Date(), candidates)
    }
}

/// 所有 API 由 JWT + owner-only RLS／RPC 驗證。Extension 與主 App 可共用同一同步實作。
public struct InboxRepository: Sendable {
    public let client: SupabaseClient

    public init(client: SupabaseClient) { self.client = client }

    public var currentUserID: UUID? { client.auth.currentUser?.id }

    public func listCaptures() async throws -> [InboxRecord] {
        do {
            return try await client.from("inbox_captures").select()
                .order("last_shared_at", ascending: false).limit(100).execute().value
        } catch { throw BackendError.from(error) }
    }

    public func capture(id: UUID) async throws -> InboxRecord? {
        do {
            let rows: [InboxRecord] = try await client.from("inbox_captures").select().eq("id", value: id)
                .limit(1).execute().value
            return rows.first
        } catch { throw BackendError.from(error) }
    }

    public func listItems(captureID: UUID) async throws -> [InboxItemRecord] {
        do {
            return try await client.from("inbox_items").select().eq("capture_id", value: captureID)
                .order("ordinal", ascending: true).execute().value
        } catch { throw BackendError.from(error) }
    }

    public func listPersonalItems(kind: String) async throws -> [InboxItemRecord] {
        do {
            return try await client.from("inbox_items").select().eq("kind", value: kind)
                .eq("archived", value: true).order("created_at", ascending: false).limit(200).execute().value
        } catch { throw BackendError.from(error) }
    }

    /// AI 找到但尚未自動歸檔的候選；使用者已撤銷的項目不再重新提示。
    public func listPersonalCandidates(kind: String) async throws -> [InboxItemRecord] {
        do {
            return try await client.from("inbox_items").select().eq("kind", value: kind)
                .eq("archived", value: false).eq("user_corrected", value: false)
                .order("created_at", ascending: false).limit(100).execute().value
        } catch { throw BackendError.from(error) }
    }

    public func pendingPlaces() async throws -> [InboxItemRecord] {
        do {
            return try await client.from("inbox_items").select().eq("kind", value: "place")
                .eq("archived", value: true).eq("resolution_status", value: "unresolved")
                .eq("origin_type", value: "explicit").eq("confidence", value: "high")
                .order("created_at", ascending: false).limit(10).execute().value
        } catch { throw BackendError.from(error) }
    }

    public func listTemplates(captureID: UUID) async throws -> [InboxTemplateRecord] {
        do {
            return try await client.from("itinerary_templates").select().eq("capture_id", value: captureID).execute().value
        } catch { throw BackendError.from(error) }
    }

    public func requestAnalysis(captureID: UUID) async throws {
        struct Params: Encodable { let capture_id: UUID }
        do {
            let _: [String: String] = try await client.functions.invoke("organize-inbox", options: FunctionInvokeOptions(
                body: Params(capture_id: captureID)))
        } catch { throw BackendError.from(error) }
    }

    /// 網路結果只有店名與可回查的來源；座標仍須由地點服務搜尋並由使用者確認。
    public func discoverPlaces(for itemID: UUID, force: Bool = false) async throws -> [DiscoveredPlace] {
        struct Body: Encodable { let item_id: UUID, force: Bool }
        struct Result: Decodable { let status: String, candidates: [DiscoveredPlace]?, reason: String? }
        let result: Result
        do {
            result = try await client.functions.invoke("discover-places", options: FunctionInvokeOptions(body: Body(item_id: itemID, force: force)))
        } catch { throw BackendError.from(error) }
        guard result.status != "failed" else { throw PlaceDiscoveryError.unavailable(result.reason ?? "unknown") }
        return result.candidates ?? []
    }

    /// 收藏頁直接選截圖時，先以裝置 OCR 的線索查韓國店名；尚未建立收件項目。
    public func discoverPlaces(query: String, context: String) async throws -> [DiscoveredPlace] {
        struct Body: Encodable { let query: String, context: String }
        struct Result: Decodable { let status: String, candidates: [DiscoveredPlace]?, reason: String? }
        let result: Result
        do {
            result = try await client.functions.invoke("discover-places", options: FunctionInvokeOptions(
                body: Body(query: String(query.prefix(200)), context: String(context.prefix(1000)))))
        } catch { throw BackendError.from(error) }
        guard result.status != "failed" else { throw PlaceDiscoveryError.unavailable(result.reason ?? "unknown") }
        return result.candidates ?? []
    }

    /// 商品與旅程地區找有來源的實體門市；只回候選，不表示有賣或有庫存。
    public func discoverStores(product: String, storeHint: String?, region: String) async throws -> [DiscoveredPlace] {
        struct Body: Encodable { let query: String, context: String, purpose: String }
        struct Result: Decodable { let status: String, candidates: [DiscoveredPlace]?, reason: String? }
        let context = ["旅程地區：\(region)", storeHint.map { "貼文店名線索：\($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
        let cacheKey = "\(currentUserID?.uuidString ?? "")|\(product)|\(storeHint ?? "")|\(region)".lowercased()
        if let cached = await StoreDiscoveryCache.shared.get(cacheKey) { return cached }
        let result: Result
        do {
            result = try await client.functions.invoke("discover-places", options: FunctionInvokeOptions(
                body: Body(query: String(product.prefix(200)), context: String(context.prefix(1000)), purpose: "product_store")))
        } catch { throw BackendError.from(error) }
        guard result.status != "failed" else { throw PlaceDiscoveryError.unavailable(result.reason ?? "unknown") }
        let candidates = result.candidates ?? []
        await StoreDiscoveryCache.shared.put(candidates, for: cacheKey)
        return candidates
    }

    /// Capture 建立後才上傳縮圖；影片保存在裝置，尚未通過影片辨識驗證。
    public func sync(_ capture: InboxCapture, from store: InboxCaptureStore) async throws -> UUID {
        guard let me = currentUserID else { throw BackendError.unauthenticated }
        guard let hint = capture.ownerHint else { throw InboxSyncError.accountConfirmationRequired }
        guard hint == me else { throw InboxSyncError.wrongAccount }
        if let syncedRemoteID = capture.syncedRemoteID { return syncedRemoteID }
        struct SaveParams: Encodable {
            let p_client_capture_id: UUID
            let p_fingerprint: String
            let p_canonical_url: String?
            let p_source_url: String?
            let p_title: String?
            let p_raw_text: String
            let p_unavailable_count: Int
        }
        struct Saved: Decodable { let id: UUID, created: Bool, same_client: Bool }
        let saved: Saved
        do {
            saved = try await client.rpc("save_inbox_capture", params: SaveParams(
                p_client_capture_id: capture.id, p_fingerprint: capture.fingerprint,
                p_canonical_url: capture.canonicalURL, p_source_url: capture.urls.first?.absoluteString,
                p_title: capture.title.map { String($0.prefix(500)) },
                p_raw_text: String(capture.rawText.prefix(20000)),
                p_unavailable_count: capture.unavailableCount
            )).execute().value
        } catch { throw BackendError.from(error) }

        if saved.created || saved.same_client {
            for asset in capture.assets {
                let kind = asset.isImage ? "image" : asset.isVideo ? "video" : "audio"
                var path: String?
                var bytes = asset.byteCount
                var digest = asset.sha256
                var mime = asset.mimeType
                if asset.isImage {
                    guard let jpeg = ImageDownscale.jpeg(fileURL: store.assetURL(captureID: capture.id, asset: asset), maxPixel: 1024)
                    else { throw InboxSyncError.uploadUnavailable }
                    bytes = jpeg.count
                    digest = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
                    mime = "image/jpeg"
                    path = "\(me.uuidString.lowercased())/\(saved.id.uuidString.lowercased())/\(asset.id.uuidString.lowercased()).jpg"
                    do {
                        _ = try await client.storage.from("inbox-images").upload(path!, data: jpeg,
                            options: FileOptions(contentType: "image/jpeg", upsert: true))
                    } catch { throw BackendError.from(error) }
                }
                struct AssetParams: Encodable {
                    let p_capture_id: UUID, p_ordinal: Int, p_kind: String, p_mime_type: String
                    let p_byte_count: Int, p_sha256: String, p_storage_path: String?
                }
                do {
                    try await client.rpc("register_inbox_asset", params: AssetParams(
                        p_capture_id: saved.id, p_ordinal: asset.order, p_kind: kind, p_mime_type: mime,
                        p_byte_count: bytes, p_sha256: digest, p_storage_path: path
                    )).execute()
                } catch { throw BackendError.from(error) }
            }
        }
        try await requestAnalysis(captureID: saved.id)
        // 有影片的原檔只在本機，不能在同步完成後刪掉。
        if capture.assets.contains(where: \.isVideo) { try store.markSynced(capture, remoteID: saved.id) }
        else { try store.remove(capture.id) }
        return saved.id
    }

    public func updateItem(_ item: InboxItemRecord, name: String? = nil, archived: Bool? = nil) async throws -> InboxItemRecord {
        struct Params: Encodable {
            let p_item_id: UUID, p_expected_revision: Int, p_display_name: String?, p_archived: Bool?
        }
        do {
            return try await client.rpc("update_inbox_item", params: Params(
                p_item_id: item.id, p_expected_revision: item.revision, p_display_name: name, p_archived: archived
            )).execute().value
        } catch { throw BackendError.from(error) }
    }

    public func confirmPlace(_ item: InboxItemRecord, placeID: UUID) async throws -> InboxItemRecord {
        struct Params: Encodable { let p_item_id: UUID, p_expected_revision: Int, p_place_id: UUID }
        do {
            return try await client.rpc("confirm_inbox_place", params: Params(
                p_item_id: item.id, p_expected_revision: item.revision, p_place_id: placeID
            )).execute().value
        } catch { throw BackendError.from(error) }
    }

    public func updateTemplate(_ template: InboxTemplateRecord, title: String, draft: InboxTemplateDraft) async throws -> InboxTemplateRecord {
        struct Params: Encodable {
            let p_template_id: UUID, p_expected_revision: Int, p_title: String, p_draft: InboxTemplateDraft
        }
        do {
            return try await client.rpc("update_inbox_template", params: Params(
                p_template_id: template.id, p_expected_revision: template.revision, p_title: title, p_draft: draft
            )).execute().value
        } catch { throw BackendError.from(error) }
    }

    /// 套用是唯一會寫正式 Trip 的入口；由畫面要求確認，RPC 以模板與每日 revision 原子提交。
    public func applyTemplate(_ template: InboxTemplateRecord, clientOperationID: UUID,
                              tripID: UUID?, startDate: String?, timeZone: String?,
                              expectedDayRevisions: [String: Int]) async throws -> UUID {
        struct Params: Encodable {
            let p_template_id: UUID, p_expected_template_revision: Int, p_client_op_id: UUID
            let p_trip_id: UUID?, p_start_date: String?, p_time_zone: String?
            let p_expected_day_revisions: [String: Int]
        }
        struct Applied: Decodable { let trip_id: UUID }
        do {
            let applied: Applied = try await client.rpc("apply_inbox_template", params: Params(
                p_template_id: template.id, p_expected_template_revision: template.revision,
                p_client_op_id: clientOperationID, p_trip_id: tripID,
                p_start_date: startDate, p_time_zone: timeZone,
                p_expected_day_revisions: expectedDayRevisions
            )).execute().value
            return applied.trip_id
        } catch { throw BackendError.from(error) }
    }
}
