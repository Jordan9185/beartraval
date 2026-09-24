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
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("密碼", text: $password)
                        .textContentType(mode == .signUp ? .newPassword : .password)
                    if mode == .signUp {
                        SecureField("再輸入一次密碼", text: $confirmation)
                            .textContentType(.newPassword)
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
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("BearTravel")
            .onChange(of: mode) { errorMessage = nil }
        }
    }

    private func submit() async {
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
