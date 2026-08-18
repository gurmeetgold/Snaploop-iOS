import SwiftUI

@main
struct SnapLoopApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @StateObject private var environment = AppEnvironment.current()
    @StateObject private var session: AppSession =
        AppEnvironment.useLiveServices ? AppSession() : .dev()

    init() {
        MyPicsTubeBrand.configureUIKitAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(session)
                .tint(Theme.sunset)
        }
    }
}
