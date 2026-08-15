import SwiftUI

@main
struct SnapLoopApp: App {
    // Toggle via the SNAPLOOP_LIVE=1 environment variable on the Xcode scheme
    // (no code edits needed). `.dev()` (default) needs zero credentials and
    // starts pre-signed-in for fast iteration on everything downstream of
    // auth. `.live()` starts signed OUT so you exercise the real phone/OTP
    // flow — see AppEnvironment.live() for exactly which seams are real today.
    @StateObject private var environment = AppEnvironment.current()
    @StateObject private var session: AppSession = AppEnvironment.useLiveServices ? AppSession() : .dev()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(session)
        }
    }
}
