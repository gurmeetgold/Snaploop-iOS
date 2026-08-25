import SwiftUI

@main
struct SnapLoopApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    init() {
        MyPicsTubeBrand.configureUIKitAppearance()
    }

    var body: some Scene {
        WindowGroup {
            AppLaunchView()
                .tint(Theme.sunset)
        }
    }
}

@MainActor
private struct AppLaunchView: View {
    @AppStorage("snaploop.onboarding.completed") private var hasCompletedOnboarding = false
    @State private var environment: AppEnvironment?
    @State private var session: AppSession?

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                OnboardingView(isCompleted: $hasCompletedOnboarding)
            } else if let environment, let session {
                RootView()
                    .environmentObject(environment)
                    .environmentObject(session)
            } else {
                startupView
            }
        }
        .task(id: hasCompletedOnboarding) {
            guard hasCompletedOnboarding else { return }
            await prepareLiveAppIfNeeded()
        }
    }

    private var startupView: some View {
        ZStack {
            BrandScreenBackground()
            VStack(spacing: 18) {
                BrandMark(size: 76)
                ProgressView()
                    .tint(Theme.lilac)
                    .controlSize(.large)
                Text("Getting SnapLoop ready…")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    private func prepareLiveAppIfNeeded() async {
        guard environment == nil || session == nil else { return }

        // Allow SwiftUI to paint the branded startup view before any SDK does
        // synchronous first-use work on the main actor.
        await Task.yield()

        let liveEnvironment = AppEnvironment.current()
        let liveSession = AppEnvironment.useLiveServices ? AppSession() : .dev()
        environment = liveEnvironment
        session = liveSession
    }
}
