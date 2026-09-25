import ShareCore
import SwiftUI

/// Email＋密碼註冊／登入。
struct LoginView: View {
    enum Mode: String, CaseIterable {
        case signIn = "登入"
        case signUp = "註冊"
    }

    let session: SessionModel
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("和旅伴一起規劃每天的行程、收藏想去的店、記下想買的東西。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                Picker("登入或註冊", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section {
                    TextField("電子郵件", text: $email)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("密碼", text: $password)
                        .textContentType(mode == .signUp ? .newPassword : .password)
                        .submitLabel(mode == .signUp ? .next : .go)
                        .onSubmit { if mode == .signIn { Task { await submit() } } }
                    if mode == .signUp {
                        SecureField("再輸入一次密碼", text: $confirmation)
                            .textContentType(.newPassword)
                            .submitLabel(.go)
                            .onSubmit { Task { await submit() } }
                    }
                } footer: {
                    if mode == .signUp {
                        Text("密碼至少 \(LoginRules.minimumPasswordLength) 個字元。")
                    }
                }

                Section {
                    Button(isSubmitting ? "處理中…" : mode.rawValue) {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || email.isEmpty || password.isEmpty)
                }

                if let errorMessage {
                    Section { ErrorText(errorMessage) }
                }
            }
            .navigationTitle("BeaRTravel")
            .onChange(of: mode) { errorMessage = nil }
        }
    }

    private func submit() async {
        guard !isSubmitting, !email.isEmpty, !password.isEmpty else { return }
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        if mode == .signUp, let problem = LoginRules.signUpProblem(email: address, password: password, confirmation: confirmation) {
            errorMessage = problem
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            switch mode {
            case .signIn: try await session.signIn(email: address, password: password)
            case .signUp: try await session.signUp(email: address, password: password)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.message
        }
    }
}
