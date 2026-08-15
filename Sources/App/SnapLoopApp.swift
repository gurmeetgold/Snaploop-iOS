import SwiftUI

@main
struct SnapLoopApp: App {
    // Phase 2 will configure Firebase (FirebaseApp.configure()) and swap
    // `.dev()` for `.live()`. Kept on in-memory services for now so the app
    // builds and runs with zero credentials.
    @StateObject private var environment = AppEnvironment.dev()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
    }
}
