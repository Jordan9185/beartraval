import Foundation
import OSLog
import Supabase

// MARK: - 錯誤訊息（plan §3.5）

extension BackendError {
    /// 給使用者看的說明；每個錯誤都要有對應的 UI（§7.2）。
    public var userMessage: String {
        switch self {
        case .unauthenticated: "登入已失效，請重新登入。"
        case .forbidden: "你的權限不足（僅檢視）。如需修改，請請擁有者調整權限。"
        case .notFound: "找不到這筆資料，可能已被刪除。"
        case .staleRevision: "行程剛被其他人修改，已載入最新版本，請重新確認。"
        case .conflict(let code):
            switch code {
            case "DUPLICATE_SAVED": "這個地點已經在收藏清單裡。"
            case "ALREADY_COMMITTED": "這份匯入已經建立過旅程。"
            case "PROPOSAL_CLOSED": "這個變更已經處理過了。"
            case "ALREADY_SCHEDULED": "這個商品已經安排好購買的店了。"
            case "ALREADY_RESOLVED": "這個收藏已經定位過了，請重新整理。"
            default: "資料衝突，請重新整理後再試。"
            }
        case .gone(let code): code == "INVITE_REVOKED" ? "邀請已被撤銷，請向擁有者索取新的邀請。" : "邀請已過期，請向擁有者索取新的邀請。"
        case .invalid(let code):
            switch code {
            case "PLACE_UNRESOLVED": "地點尚未確認，無法加入行程或計算路線。"
            case "INVALID_DATES": "結束日期不能早於開始日期。"
            case "EMPTY_TEXT": "請先貼上行程文字。"
            case "RATE_LIMITED": "使用次數已達上限，請稍後再試。"
            default: "資料格式不正確，請檢查後再試。"
            }
        case .other: "無法連線，請檢查網路後再試。"
        }
    }

    /// 暫時性錯誤（網路），可稍後重試或排入離線佇列。
    public var isTransient: Bool {
        if case .other = self { true } else { false }
    }
}

extension RouteEstimate.UnavailableReason {
    public var userMessage: String {
        switch self {
        case .notSupportedInRegion: "無法估算：地圖服務在這個地區不提供此交通方式。"
        case .unconfirmedPlace: "無法估算：地點尚未確認。"
        case .network: "無法估算：目前沒有網路。"
        case .throttled: "路線服務忙碌中，請稍後重試。"
        case .unknown: "無法估算這段路線。"
        }
    }
}

/// 任何錯誤轉成給使用者看的中文原因：不露出系統英文訊息或錯誤碼（審查：錯誤訊息）。
public func userMessage(for error: any Error) -> String {
    if let error = error as? URLError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dataNotAllowed:
            return "無法連線，請檢查網路後再試。"
        default:
            return "連線發生問題，請稍後再試。"
        }
    }
    let backend = BackendError.from(error)
    if case .other = backend { return "發生問題，請稍後再試。" }
    return backend.userMessage
}

// MARK: - 刪除（plan §3.1）

extension TripRepository {
    /// Owner 刪除整個 Trip（含匯入原文與 AI 紀錄）。
    public func deleteTrip(_ tripID: UUID) async throws {
        struct Params: Encodable { let p_trip_id: UUID }
        do { try await client.rpc("delete_trip", params: Params(p_trip_id: tripID)).execute() }
        catch { throw BackendError.from(error) }
    }

    /// 刪除帳號：擁有的 Trip 轉給其他成員或刪除，協作紀錄匿名化，然後登出。
    public func deleteAccount() async throws {
        struct Response: Decodable { let status: String }
        do {
            let r: Response = try await client.functions.invoke("delete-account", options: FunctionInvokeOptions(method: .post))
            guard r.status == "deleted" else { throw BackendError.other("DELETE_FAILED") }
            try? await client.auth.signOut(scope: .local)
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.from(error)
        }
    }
}

// MARK: - 離線唯讀快取（決策 D6）

public struct SnapshotCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func shared() -> SnapshotCache? {
        AppGroup.containerURL.map { SnapshotCache(directory: $0.appending(path: "SnapshotCache", directoryHint: .isDirectory)) }
    }

    public struct Entry: Codable, Sendable {
        public var savedAt: Date
        public var snapshot: TripSnapshot
    }

    // 用 Date 的原生表示（reference date 起算的 Double），讀回完全一致；
    // ISO 字串或 1970 起算的秒數都會有浮點捨入誤差。
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    public func save(_ snapshot: TripSnapshot, at date: Date = Date()) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Self.encoder.encode(Entry(savedAt: date, snapshot: snapshot))
            .write(to: directory.appending(path: "\(snapshot.trip.id.uuidString).json"), options: .atomic)
    }

    public func load(tripID: UUID) -> Entry? {
        guard let data = try? Data(contentsOf: directory.appending(path: "\(tripID.uuidString).json")) else { return nil }
        return try? Self.decoder.decode(Entry.self, from: data)
    }

    public func remove(tripID: UUID) {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(tripID.uuidString).json"))
    }

    /// 登出時清掉，下一個帳號離線開 App 不會看到上一個帳號的旅程。
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - 可觀測性：路線與 AI 呼叫的延遲、錯誤

public actor Telemetry {
    public static let shared = Telemetry()
    static let log = Logger(subsystem: "beartravel", category: "telemetry")

    public struct Stats: Sendable, Equatable {
        public var count = 0
        public var failures: [String: Int] = [:]
        public var latenciesMs: [Int] = []

        public var p50: Int? { percentile(0.5) }
        public var p95: Int? { percentile(0.95) }

        func percentile(_ p: Double) -> Int? {
            guard !latenciesMs.isEmpty else { return nil }
            let sorted = latenciesMs.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
    }

    public private(set) var stats: [String: Stats] = [:]

    public init() {}

    /// `kind` 例如 `route.walking`、`ai.ask`；`failure` 為 nil 表示成功。
    public func record(_ kind: String, latencyMs: Int, failure: String? = nil) {
        var s = stats[kind, default: Stats()]
        s.count += 1
        s.latenciesMs.append(latencyMs)
        if s.latenciesMs.count > 500 { s.latenciesMs.removeFirst(s.latenciesMs.count - 500) }
        if let failure { s.failures[failure, default: 0] += 1 }
        stats[kind] = s
        Self.log.info("\(kind, privacy: .public) \(latencyMs)ms \(failure ?? "ok", privacy: .public)")
    }

    public func reset() { stats = [:] }
}

/// 為任一路線供應商記錄延遲與失敗原因。
public struct InstrumentedProvider: RoutingProvider {
    let base: any RoutingProvider
    let telemetry: Telemetry

    public init(_ base: any RoutingProvider, telemetry: Telemetry = .shared) {
        self.base = base
        self.telemetry = telemetry
    }

    public var id: RouteProvider { base.id }

    public func travelTime(from: Coordinate, to: Coordinate, mode: TravelMode, departure: Date) async -> LegTime {
        let start = ContinuousClock.now
        let result = await base.travelTime(from: from, to: to, mode: mode, departure: departure)
        let ms = Int((ContinuousClock.now - start).components.seconds * 1000 + (ContinuousClock.now - start).components.attoseconds / 1_000_000_000_000_000)
        var failure: String?
        if case .unavailable(let reason) = result { failure = reason.rawValue }
        await telemetry.record("route.\(mode.rawValue)", latencyMs: ms, failure: failure)
        return result
    }
}
