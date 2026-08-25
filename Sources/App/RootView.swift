import FirebaseAuth
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
            } else if let user = session.user,
                      user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                      !session.skippedNameSetup {
                NavigationStack { ProfileNameView(allowsDeferral: true) }
            } else if session.user != nil && !session.isFaceProfileResolved {
                openingView
            } else if session.user != nil && !session.hasFaceProfile && !session.skippedFaceSetup {
                NavigationStack { FaceSetupView(allowsDeferral: true) }
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
                if session.user != nil && session.hasFaceProfile { configureAutomaticSyncAndRun() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .myPicsRoomInviteReceived)) { _ in
            guard hasCompletedOnboarding else { return }
            Task { await loadPendingInviteIfNeeded() }
        }
        .onOpenURL { url in handleIncomingURL(url) }
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

            if !session.isFaceProfileResolved {
                await hydrateFaceProfileIfNeeded(userId: userId)
            }
            _ = await (configRefresh, inviteLoad, pushRegistration)

            if session.user?.id == userId && session.hasFaceProfile {
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

            let faceProfile: FaceProfile?
            if let stored,
               stored.userId == userId,
               stored.version == FaceModelPolicy.currentVersion {
                faceProfile = stored
            } else {
                faceProfile = nil
            }
            session.setResolvedFaceProfile(faceProfile, forUserId: userId)

            if var user = session.user, (faceProfile != nil) != user.hasFaceProfile {
                user.hasFaceProfile = faceProfile != nil
                session.updateUser(user)
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
    private func handleIncomingURL(_ url: URL) {
        if AppEnvironment.useLiveServices && Auth.auth().canHandle(url) {
            Log.auth.info("Firebase Auth callback handled for scheme: \(url.scheme ?? "unknown", privacy: .public)")
            return
        }
        captureInvite(url)
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
    private func clearStaleAuthenticatedSession(reason: Error) {
        Log.auth.error("Clearing stale authenticated session: \(String(describing: reason), privacy: .public)")
        do {
            try environment.auth.signOut()
        } catch {
            Log.auth.error("Firebase sign-out while clearing stale session failed: \(String(describing: error), privacy: .public)")
        }
        session.clearAuthenticatedSession()
        postAuthUserId = nil
    }

    private func isMissingOrInvalidAccount(_ error: Error) -> Bool {
        guard let appError = error as? AppError else { return false }
        switch appError {
        case .backend(let code, _):
            return code == "user_not_found" || code == "permission_denied" || code == "failed_precondition"
        case .notAuthenticated:
            return true
        default:
            return false
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
            session.beginAuthenticatedSession(user: cachedUser, faceProfile: nil, faceProfileResolved: false)
            isBootstrappingSession = false
            Task { await refreshPersistedUser(userId: uid) }
            return
        }

        do {
            let user = try await environment.users.fetch(userId: uid)
            session.beginAuthenticatedSession(user: user, faceProfile: nil, faceProfileResolved: false)
        } catch {
            if isMissingOrInvalidAccount(error) {
                clearStaleAuthenticatedSession(reason: error)
            } else {
                Log.auth.error("Persisted user refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
        isBootstrappingSession = false
    }

    @MainActor
    private func refreshPersistedUser(userId: String) async {
        do {
            let refreshed = try await environment.users.fetch(userId: userId)
            guard session.user?.id == userId else { return }
            session.updateUser(refreshed)
        } catch {
            guard session.user?.id == userId else { return }
            if isMissingOrInvalidAccount(error) {
                clearStaleAuthenticatedSession(reason: error)
            } else {
                Log.auth.error("Background user refresh failed: \(String(describing: error), privacy: .public)")
            }
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
