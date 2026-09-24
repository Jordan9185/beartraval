import Testing
@testable import Features

struct LoginRulesTests {
    @Test(arguments: ["a@b.co", "tester@example.com"])
    func acceptsEmail(_ email: String) {
        #expect(LoginRules.isValidEmail(email))
    }

    @Test(arguments: ["", "abc", "a@b", "@b.co", "a b@c.co", "a@@b.co"])
    func rejectsEmail(_ email: String) {
        #expect(!LoginRules.isValidEmail(email))
    }

    @Test func signUpChecksLengthAndConfirmation() {
        #expect(LoginRules.signUpProblem(email: "a@b.co", password: "short", confirmation: "short") != nil)
        #expect(LoginRules.signUpProblem(email: "a@b.co", password: "longenough", confirmation: "different") == "兩次輸入的密碼不一致。")
        #expect(LoginRules.signUpProblem(email: "a@b.co", password: "longenough", confirmation: "longenough") == nil)
    }
}
