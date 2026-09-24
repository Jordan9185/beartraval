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
    public let client: SupabaseClient
    public let trips: TripRepository

    public init(client: SupabaseClient) {
        self.client = client
        self.trips = TripRepository(client: client)
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

    /// Magic link 開回 App。
    public func handle(url: URL) async throws {
        _ = try await client.auth.session(from: url)
    }

    public func sendMagicLink(email: String) async throws {
        try await client.auth.signInWithOTP(email: email, redirectTo: Backend.loginCallbackURL)
    }

    public func signInWithApple(idToken: String, nonce: String) async throws {
        _ = try await client.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: idToken, nonce: nonce))
    }

    public func signOut() async {
        try? await client.auth.signOut()
    }
}
