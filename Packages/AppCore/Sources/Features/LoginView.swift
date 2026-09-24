import AuthenticationServices
import CryptoKit
import SwiftUI

/// Sign in with Apple + Email magic link。
struct LoginView: View {
    let session: SessionModel
    @State private var email = ""
    @State private var nonce = ""
    @State private var sentTo: String?
    @State private var errorMessage: String?
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SignInWithAppleButton(.signIn) { request in
                        nonce = Self.randomNonce()
                        request.requestedScopes = [.email]
                        request.nonce = Self.sha256(nonce)
                    } onCompletion: { result in
                        Task { await completeApple(result) }
                    }
                    .frame(height: 44)
                }
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button(isSending ? "寄送中…" : "寄送登入連結") {
                        Task { await sendLink() }
                    }
                    .disabled(isSending || !email.contains("@"))
                } header: {
                    Text("或用 Email 登入")
                } footer: {
                    if let sentTo {
                        Text("已寄出登入連結到 \(sentTo)，請在這支手機上開啟信件中的連結。")
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("登入 BearTravel")
        }
    }

    private func sendLink() async {
        isSending = true
        defer { isSending = false }
        let address = email.trimmingCharacters(in: .whitespaces)
        do {
            try await session.sendMagicLink(email: address)
            sentTo = address
            errorMessage = nil
        } catch {
            errorMessage = "寄送失敗：\(error.localizedDescription)"
        }
    }

    private func completeApple(_ result: Result<ASAuthorization, any Error>) async {
        do {
            let authorization = try result.get()
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8)
            else {
                errorMessage = "Apple 沒有回傳 identity token。"
                return
            }
            try await session.signInWithApple(idToken: idToken, nonce: nonce)
            errorMessage = nil
        } catch ASAuthorizationError.canceled {
            // 使用者取消，不顯示錯誤。
        } catch {
            errorMessage = "Apple 登入失敗：\(error.localizedDescription)"
        }
    }

    static func randomNonce() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
