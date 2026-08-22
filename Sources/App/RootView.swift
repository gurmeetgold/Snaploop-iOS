import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("snaploop.onboarding.completed") private var hasCompletedOnboarding = false
    @State private var didBootstrapSession = false
    @State private var isBootstrappingSession = false
    @State private var postAuthUserId: String?

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                OnboardingView(isCompleted: $hasCompletedOnboarding)
            } else if isBootstrappingSession || (session.user == nil && environment.auth.currentUserId != nil) {
                openingView
            } else if session.user != nil {
                MainTabView()
                    .sheet(item: $session.pendingRoute) { route in
                        NavigationStack {
                            JoinEventView(route: route) { event in
                                PendingInviteStore.clear()
                                session.pendingRoute = nil
                                session.activeEvent = event
                            }
                        }
                    }
            } else {
                PhoneAuthFlowView()
            }
        }
        .tint(Theme.lilac)
        .task {
            guard hasCompletedOnboarding else { return }
            await bootstrapPersistedSessionIfNeeded()
            kickOffDeferredStartupWork()
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            guard completed else { return }
            Task {
                await bootstrapPersistedSessionIfNeeded()
                kickOffDeferredStartupWork()
            }
        }
        .onChange(of: session.user?.id) { _, userId in
            guard let userId else {
                postAuthUserId = nil
                return
            }
            guard postAuthUserId != userId else { return }
            kickOffDeferredStartupWork()
        }
        .onChange(of: session.hasFaceProfile) { _, hasFaceProfile in
            guard hasFaceProfile, session.user != nil else { return }
            configureAutomaticSyncAndRun()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, hasCompletedOnboarding else { return }
            Task {
                await loadPendingInviteIfNeeded()
                if session.user != nil { configureAutomaticSyncAndRun() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .myPicsRoomInviteReceived)) { _ in
            guard hasCompletedOnboarding else { return }
            Task { await loadPendingInviteIfNeeded() }
        }
        .onOpenURL { url in captureInvite(url) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { captureInvite(url) }
        }
    }

    private var openingView: some View {
        ZStack {
            BrandScreenBackground()
            VStack(spacing: 20) {
                BrandMark(size: 78)
                ProgressView()
                    .tint(Theme.lilac)
                    .controlSize(.large)
                Text("Signing you in…")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("Restoring your secure SnapLoop session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func kickOffDeferredStartupWork() {
        guard let userId = session.user?.id else {
            Task { await environment.config.refresh() }
            return
        }
        guard postAuthUserId != userId else { return }
        postAuthUserId = userId

        Task {
            async let configRefresh: Void = environment.config.refresh()
            async let inviteLoad: Void = loadPendingInviteIfNeeded()
            async let pushRegistration: Void = PushNotificationClient.requestAuthorizationAndRegister()

            await hydrateFaceProfileIfNeeded(userId: userId)
            _ = await (configRefresh, inviteLoad, pushRegistration)

            if session.user?.id == userId {
                configureAutomaticSyncAndRun()
            }
        }
    }

    @MainActor
    private func hydrateFaceProfileIfNeeded(userId: String) async {
        guard session.user?.id == userId else { return }
        do {
            let stored = try await environment.faceProfiles.load(userId: userId)
            guard session.user?.id == userId else { return }

            let faceProfile = stored?.version == FaceModelPolicy.currentVersion ? stored : nil
            session.faceProfile = faceProfile

            if var user = session.user, (faceProfile != nil) != user.hasFaceProfile {
                user.hasFaceProfile = faceProfile != nil
                session.user = user
                SessionUserCache.save(user)
                try? await environment.users.save(user)
            }
        } catch {
            Log.events.error("Deferred face-profile hydration failed: \(String(describing: error), privacy: .public)")
        }
    }

    @MainActor
    private func configureAutomaticSyncAndRun() {
        AutomaticEventSync.shared.configure(environment: environment, session: session)
        AutomaticEventSync.shared.runWhenAppBecomesActive()
    }

    @MainActor
    private func captureInvite(_ url: URL) {
        if let route = DeepLinkRouter.route(for: url) {
            PendingInviteStore.save(route)
            session.pendingRoute = route
        }
    }

    @MainActor
    private func loadPendingInviteIfNeeded() async {
        guard session.user != nil, session.pendingRoute == nil else { return }
        if let stored = PendingInviteStore.load() {
            session.pendingRoute = stored
            return
        }
        guard AppEnvironment.useLiveServices else { return }
        do {
            if let route = try await EventInviteClient.nextPendingRoute() {
                PendingInviteStore.save(route)
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
        guard session.user == nil else { return }

        isBootstrappingSession = true
        let uid = await environment.auth.resolvedCurrentUserId()

        guard let uid else {
            isBootstrappingSession = false
            return
        }

        if let cachedUser = SessionUserCache.load(userId: uid) {
            session.beginAuthenticatedSession(user: cachedUser, faceProfile: nil)
            isBootstrappingSession = false
            Task { await refreshPersistedUser(userId: uid) }
            return
        }

        do {
            let user = try await environment.users.fetch(userId: uid)
            session.beginAuthenticatedSession(user: user, faceProfile: nil)
        } catch {
            Log.auth.error("Persisted user refresh failed: \(String(describing: error), privacy: .public)")
        }
        isBootstrappingSession = false
    }

    @MainActor
    private func refreshPersistedUser(userId: String) async {
        do {
            let refreshed = try await environment.users.fetch(userId: userId)
            guard session.user?.id == userId else { return }
            session.user = refreshed
            SessionUserCache.save(refreshed)
        } catch {
            Log.auth.error("Background user refresh failed: \(String(describing: error), privacy: .public)")
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { AllMyPhotosView() }
                .tabItem { Label("Gallery", systemImage: "photo.on.rectangle.angled") }
            NavigationStack { SettingsView() }
                .tabItem { Label("You", systemImage: "person.crop.circle.fill") }
        }
        .tint(Theme.coral)
        .toolbarBackground(Theme.surface.opacity(0.97), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}
