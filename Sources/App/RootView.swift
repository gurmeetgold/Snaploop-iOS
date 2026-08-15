import SwiftUI

/// Top-level router. Renders Home, and captures inbound invite links/QLR into a
/// pending route on the session. Auth + Onboarding + FaceProfile gates are
/// layered in as those features are built; for now a dev session is signed in.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var session: AppSession

    var body: some View {
        HomeView()
            // Universal Links (https://snaploop.app/e/…) and the custom scheme.
            .onOpenURL { url in
                if let route = DeepLinkRouter.route(for: url) {
                    // Stash it; replay once the user is registered + face is set.
                    session.pendingRoute = route
                }
            }
            .sheet(item: $session.pendingRoute) { route in
                NavigationStack {
                    JoinEventView(route: route) { _ in session.pendingRoute = nil }
                }
            }
    }
}

#Preview {
    RootView()
        .environmentObject(AppEnvironment.dev())
        .environmentObject(AppSession.dev())
}
