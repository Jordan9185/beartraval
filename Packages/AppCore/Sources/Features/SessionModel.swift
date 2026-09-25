import AppCore
import Foundation
import Observation
import Supabase

/// 登入狀態。App 與 Share Extension 透過共用 Keychain 讀到同一個 session。
@MainActor
@Observable
public final class SessionModel {
    public enum State: Equatable {
        case loading
        case signedOut
        case signedIn(email: String?)
    }

    public private(set) var state: State = .loading
    /// 從 beartravel://invite 開啟時待處理的邀請。
    public var pendingInviteToken: String?
    /// 離線佇列（Saved 想去、收藏等）；恢復連線時送出。
    public let offlineQueue = OfflineQueue.shared()
    public let client: SupabaseClient
    public let trips: TripRepository
    /// 同一個 matcher（與快取）供 Base Route 與 Route Match 共用，確保同一計算基準。
    public let routes: RouteMatcher
    public let imports: any ImportService
    public let placeSearch: any PlaceSearching

    public let network = NetworkMonitor()

    public init(client: SupabaseClient, routingProvider: any RoutingProvider = InstrumentedProvider(AppleMapKitProvider())) {
        self.client = client
        self.trips = TripRepository(client: client)
        self.routes = RouteMatcher(provider: routingProvider)
        self.imports = SupabaseImportService(client: client)
        self.placeSearch = MapKitPlaceSearch()
        Task { await observe() }
    }

    private func observe() async {
        for await (_, session) in client.auth.authStateChanges {
            // 本機存的 session 可能已過期；過期的視為未登入，SDK 會嘗試自動更新。
            if let session, !session.isExpired {
                state = .signedIn(email: session.user.email)
            } else {
                state = .signedOut
            }
        }
    }

    /// Email＋密碼註冊。後端需關閉 Email 確認，註冊後直接登入。
    public func signUp(email: String, password: String) async throws(LoginError) {
        do {
            let response = try await client.auth.signUp(email: email, password: password)
            if case .user = response {
                throw LoginError.confirmationRequired
            }
        } catch let error as LoginError {
            throw error
        } catch {
            throw LoginError(error)
        }
    }

    public func signIn(email: String, password: String) async throws(LoginError) {
        do {
            _ = try await client.auth.signIn(email: email, password: password)
        } catch {
            throw LoginError(error)
        }
    }

    /// 處理 App 連結（目前只有邀請）。
    public func handle(url: URL) {
        if url.scheme == "beartravel", url.host == "invite", let token = InviteLink.token(from: url.absoluteString) {
            pendingInviteToken = token
        }
    }

    public func flushOfflineQueue() async {
        _ = await offlineQueue.flush(using: trips)
    }

    public func signOut() async {
        try? await client.auth.signOut()
    }
}

public enum LoginError: Error, Equatable {
    case invalidCredentials
    case emailTaken
    case weakPassword
    /// 後端開著 Email 確認；MVP 設定應關閉（supabase/README.md）。
    case confirmationRequired
    case other(String)

    init(_ error: any Error) {
        guard let auth = error as? AuthError else {
            self = .other(error.localizedDescription)
            return
        }
        switch auth.errorCode {
        case .invalidCredentials: self = .invalidCredentials
        case .userAlreadyExists, .emailExists: self = .emailTaken
        case .weakPassword: self = .weakPassword
        default:
            if case .weakPassword = auth { self = .weakPassword } else { self = .other(auth.localizedDescription) }
        }
    }

    public var message: String {
        switch self {
        case .invalidCredentials: "電子郵件或密碼錯誤。"
        case .emailTaken: "這個電子郵件已經註冊過，請直接登入。"
        case .weakPassword: "密碼強度不足，請至少 \(LoginRules.minimumPasswordLength) 個字元。"
        case .confirmationRequired: "帳號已建立，但後端要求驗證電子郵件；請聯絡管理者關閉驗證。"
        case .other(let message): "登入失敗：\(message)"
        }
    }
}

/// 送出前的本機檢查；最終以後端規則為準。
public enum LoginRules {
    /// 與 supabase/config.toml 的 `minimum_password_length` 一致。
    public static let minimumPasswordLength = 8

    public static func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !email.contains(" ")
    }

    public static func signUpProblem(email: String, password: String, confirmation: String) -> String? {
        if !isValidEmail(email) { return "請輸入有效的電子郵件。" }
        if password.count < minimumPasswordLength { return "密碼至少 \(minimumPasswordLength) 個字元。" }
        if password != confirmation { return "兩次輸入的密碼不一致。" }
        return nil
    }
}
