import AppCore
import Features
import SwiftUI

@main
struct BearTravelApp: App {
    @State private var session = BackendConfig.fromBundle().map { SessionModel(client: Backend.makeClient($0)) }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // XCUITest：`-UITestImport <scenario>` 直接進匯入流程（假服務，不連後端）。
            if let scenario = UserDefaults.standard.string(forKey: "UITestImport") {
                ImportUITestRoot(scenario: scenario)
            } else if UserDefaults.standard.bool(forKey: "UITestShopping") {
                ShoppingUITestRoot()
            } else {
                RootView(session: session).onOpenURL { session?.handle(url: $0) }
            }
            #else
            RootView(session: session).onOpenURL { session?.handle(url: $0) }
            #endif
        }
    }
}
