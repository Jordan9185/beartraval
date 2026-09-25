import Foundation
import Supabase

/// 後端連線設定，由 xcconfig 寫入 Info.plist（`SupabaseURL`、`SupabaseAnonKey`）。
public struct BackendConfig: Sendable {
    public var url: URL
    public var anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> BackendConfig? {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            let url = URL(string: urlString), url.host != nil,
            let key = bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String, !key.isEmpty
        else { return nil }
        return BackendConfig(url: url, anonKey: key)
    }
}

public enum Backend {
    /// App 與 Share Extension 用同一個 Keychain access group（= App Group）共用登入。
    public static func makeClient(
        _ config: BackendConfig,
        storage: any AuthLocalStorage = KeychainLocalStorage(accessGroup: AppGroup.keychainAccessGroup)
    ) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.anonKey,
            options: SupabaseClientOptions(
                db: .init(schema: "app"),
                auth: .init(
                    storage: storage,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }
}

/// 後端 RPC 的錯誤（SQLSTATE `PTnnn`，見 supabase/README.md）。
public enum BackendError: Error, Equatable, Sendable {
    case unauthenticated
    case forbidden
    case notFound
    case staleRevision
    /// 其他 409（例如 `DUPLICATE_SAVED`、`ALREADY_COMMITTED`）。
    case conflict(String)
    case gone(String)
    case invalid(String)
    case other(String)

    public init(code: String?, message: String) {
        switch code {
        case "PT401": self = .unauthenticated
        case "PT403": self = .forbidden
        case "PT404": self = .notFound
        case "PT409": self = message == "STALE_REVISION" ? .staleRevision : .conflict(message)
        case "PT410": self = .gone(message)
        case "PT422": self = .invalid(message)
        // 其他 Postgres／PostgREST 錯誤是伺服器拒絕，不是網路問題：不可排入離線佇列一直重送（審查）。
        case "42501": self = .forbidden
        case "PGRST116": self = .notFound
        case let code? where code.hasPrefix("22") || code.hasPrefix("23") || code.hasPrefix("42") || code.hasPrefix("P0")
            || code.hasPrefix("PGRST"):
            self = .invalid(code)
        default: self = .other(message)
        }
    }

    public static func from(_ error: any Error) -> BackendError {
        if let error = error as? BackendError { return error }
        if let error = error as? PostgrestError { return BackendError(code: error.code, message: error.message) }
        if case FunctionsError.httpError(let status, _) = error { return BackendError(httpStatus: status) }
        return .other(error.localizedDescription)
    }

    /// Edge Function 的 HTTP 狀態：5xx 視為暫時性，4xx 是被拒絕。
    init(httpStatus: Int) {
        switch httpStatus {
        case 401: self = .unauthenticated
        case 403: self = .forbidden
        case 404: self = .notFound
        case 409: self = .conflict("HTTP_409")
        case 429: self = .invalid("RATE_LIMITED")
        case 400..<500: self = .invalid("HTTP_\(httpStatus)")
        default: self = .other("HTTP_\(httpStatus)")
        }
    }
}
