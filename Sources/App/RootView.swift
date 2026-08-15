import SwiftUI

/// Top-level router. Phase 1 renders the signed-in Home skeleton; the auth and
/// onboarding gates are wired in as those features are built out. Kept
/// deliberately thin — it only chooses which flow is on screen.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        HomeView()
    }
}

#Preview {
    RootView().environmentObject(AppEnvironment.dev())
}
