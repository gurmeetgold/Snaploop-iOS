import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var didBootstrapSession = false
    @State private var isBootstrappingSession = false

    var body: some View {
        Group {
            if isBootstrappingSession {
                ZStack {
                    BrandScreenBackground()
                    VStack(spacing: 18) {
                        BrandMark(size: 68)
                        ProgressView()
                            .tint(Theme.sunset)
                        Text("Opening MyPicsTube…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
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
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await loadPendingInviteIfNeeded() }
        }
        .onOpenURL { url in captureInvite(url) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { captureInvite(url) }
        }
    }

    @MainActor
    private func captureInvite(_ url: URL) {
        if let route = DeepLinkRouter.route(for: url) {
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
    enum Tab { case home, events, shared, you }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(showsGreeting: true) }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            NavigationStack { HomeView(showsGreeting: false) }
                .tabItem { Label("Events", systemImage: "calendar.badge.clock") }
                .tag(Tab.events)

            NavigationStack { ActiveEventSharedView() }
                .tabItem { Label("Shared", systemImage: "person.2.crop.square.stack.fill") }
                .tag(Tab.shared)

            NavigationStack { SettingsView() }
                .tabItem { Label("You", systemImage: "person.crop.circle.fill") }
                .tag(Tab.you)
        }
        .tint(Theme.sunset)
    }
}

private struct ActiveEventSharedView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        if let event = session.activeEvent {
            SharedAlbumView(event: event)
        } else {
            ZStack {
                BrandScreenBackground()
                PremiumCard {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle().fill(Theme.sky.opacity(0.14))
                            Image(systemName: "person.2.crop.square.stack")
                                .font(.system(size: 34))
                                .foregroundStyle(Theme.sky)
                        }
                        .frame(width: 76, height: 76)
                        Text("Pick an event")
                            .font(.title3.bold())
                            .foregroundStyle(Theme.ink)
                        Text("Open an event from Home or Events to see its shared album here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .padding(24)
            }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppEnvironment.dev())
        .environmentObject(AppSession.dev())
}
