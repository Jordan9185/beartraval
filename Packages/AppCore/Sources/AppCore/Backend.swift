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
        storage: any AuthLocalStorage = KeychainLocalStorage(accessGroup: AppGroup.identifier)
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
        default: self = .other(message)
        }
    }

    public static func from(_ error: any Error) -> BackendError {
        if let error = error as? BackendError { return error }
        if let error = error as? PostgrestError { return BackendError(code: error.code, message: error.message) }
        return .other(error.localizedDescription)
    }
}
