import AppCore
import Features
import SwiftUI

@main
struct BearTravelApp: App {
    @State private var session = BackendConfig.fromBundle().map { SessionModel(client: Backend.makeClient($0)) }

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .onOpenURL { url in
                    Task { try? await session?.handle(url: url) }
                }
        }
    }
}
