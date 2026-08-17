import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @State private var didBootstrapSession = false
    @State private var isBootstrappingSession = false

    var body: some View {
        Group {
            if isBootstrappingSession {
                ProgressView("Opening SnapLoop…")
            } else if session.user != nil {
                MainTabView()
                    .sheet(item: $session.pendingRoute) { route in
                        NavigationStack {
                            JoinEventView(route: route) { event in
                                session.pendingRoute = nil
                                session.activeEvent = event
                            }
                        }
                    }
            } else {
                PhoneAuthFlowView()
            }
        }
        .task {
            await environment.config.refresh()
            await bootstrapPersistedSessionIfNeeded()
            await loadPendingInviteIfNeeded()
        }
        .onChange(of: session.user?.id) { _, userId in
            guard userId != nil else { return }
            Task { await loadPendingInviteIfNeeded() }
        }
        .onOpenURL { captureInvite($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { captureInvite(url) }
        }
    }

    @MainActor
    private func captureInvite(_ url: URL) {
        if let route = DeepLinkRouter.route(for: url) { session.pendingRoute = route }
    }

    @MainActor
    private func loadPendingInviteIfNeeded() async {
        guard AppEnvironment.useLiveServices,
              session.user != nil,
              session.pendingRoute == nil else { return }
        do {
            if let route = try await EventInviteClient.nextPendingRoute() {
                session.pendingRoute = route
            }
        } catch {
            Log.events.error("Pending invite lookup failed: \(String(describing: error), privacy: .public)")
        }
    }

    @MainActor
    private func bootstrapPersistedSessionIfNeeded() async {
        guard !didBootstrapSession else { return }
        didBootstrapSession = true
        guard session.user == nil, let uid = environment.auth.currentUserId else { return }
        isBootstrappingSession = true
        defer { isBootstrappingSession = false }

        do {
            var user = try await environment.users.fetch(userId: uid)
            let storedFaceProfile = try await environment.faceProfiles.load(userId: uid)
            let faceProfile = storedFaceProfile?.version == FaceModelPolicy.currentVersion ? storedFaceProfile : nil
            if (faceProfile != nil) != user.hasFaceProfile {
                user.hasFaceProfile = faceProfile != nil
                try await environment.users.save(user)
            }
            session.beginAuthenticatedSession(user: user, faceProfile: faceProfile)
        } catch {
            try? environment.auth.signOut()
            session.clearAuthenticatedSession()
        }
    }
}

struct MainTabView: View {
    @State private var selectedTab = Tab.home
    enum Tab { case home, events, shared, you }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(showsGreeting: true) }
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(Tab.home)
            NavigationStack { HomeView(showsGreeting: false) }
                .tabItem { Label("Events", systemImage: "calendar") }.tag(Tab.events)
            NavigationStack { ActiveEventSharedView() }
                .tabItem { Label("Shared", systemImage: "person.2.fill") }.tag(Tab.shared)
            NavigationStack { SettingsView() }
                .tabItem { Label("You", systemImage: "person.crop.circle.fill") }.tag(Tab.you)
        }
        .tint(Theme.coral)
    }
}

private struct ActiveEventSharedView: View {
    @EnvironmentObject private var session: AppSession
    var body: some View {
        if let event = session.activeEvent {
            SharedAlbumView(event: event)
        } else {
            ContentUnavailableViewCompat(
                title: "Pick an event",
                message: "Open an event from Home to see its shared photos here.",
                systemImage: "person.2"
            )
        }
    }
}

#Preview {
    RootView().environmentObject(AppEnvironment.dev()).environmentObject(AppSession.dev())
}
