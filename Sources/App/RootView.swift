import SwiftUI

/// Top-level router. In live mode it first restores a persisted Firebase Auth
/// session into the Firestore-backed SnapLoop user/profile session.
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
        .onOpenURL { url in
            captureInvite(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { captureInvite(url) }
        }
    }

    @MainActor
    private func captureInvite(_ url: URL) {
        if let route = DeepLinkRouter.route(for: url) {
            // Keep the route even if authentication/Face Setup is not ready.
            // It is replayed once the signed-in MainTabView becomes available.
            session.pendingRoute = route
        }
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
            // A pending-invite check must never prevent the app from opening.
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
            let faceProfile = storedFaceProfile?.version == FaceModelPolicy.currentVersion
                ? storedFaceProfile : nil

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
    enum Tab { case home, trips, shared, requests, you }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(showsGreeting: true) }
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(Tab.home)
            NavigationStack { HomeView(showsGreeting: false) }
                .tabItem { Label("Trips", systemImage: "suitcase.fill") }.tag(Tab.trips)
            NavigationStack { ActiveEventScopedView(kind: .shared) }
                .tabItem { Label("Shared", systemImage: "person.2.fill") }.tag(Tab.shared)
            NavigationStack { ActiveEventScopedView(kind: .requests) }
                .tabItem { Label("Requests", systemImage: "bell.fill") }.tag(Tab.requests)
            NavigationStack { SettingsView() }
                .tabItem { Label("You", systemImage: "person.crop.circle.fill") }.tag(Tab.you)
        }
        .tint(Theme.coral)
    }
}

private struct ActiveEventScopedView: View {
    enum Kind { case shared, requests }
    let kind: Kind
    @EnvironmentObject private var session: AppSession

    var body: some View {
        if let event = session.activeEvent {
            switch kind {
            case .shared: SharedAlbumView(event: event)
            case .requests: RequestsView(event: event)
            }
        } else {
            ContentUnavailableViewCompat(
                title: "Pick a trip",
                message: "Open a trip from Home to see its \(kind == .shared ? "shared album" : "requests") here.",
                systemImage: kind == .shared ? "person.2" : "bell")
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppEnvironment.dev())
        .environmentObject(AppSession.dev())
}
