import SwiftUI

@main
struct SnapLoopApp: App {

    // Bridges SwiftUI's app lifecycle to UIApplicationDelegate.
    //
    // Firebase Phone Auth needs UIApplicationDelegate callbacks for:
    // - APNs device registration
    // - silent authentication notifications
    // - reCAPTCHA callback URLs
    @UIApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    // Toggle via SNAPLOOP_LIVE=1 in the Xcode scheme.
    //
    // .dev():
    // - no Firebase
    // - no credentials
    // - pre-signed-in dev session
    //
    // .live():
    // - Firebase Auth
    // - starts signed out
    // - real phone/OTP flow
    @StateObject private var environment = AppEnvironment.current()

    @StateObject private var session: AppSession =
        AppEnvironment.useLiveServices ? AppSession() : .dev()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(session)
        }
    }
}
