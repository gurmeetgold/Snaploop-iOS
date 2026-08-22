import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("snaploop.onboarding.completed") private var hasCompletedOnboarding = false
    @State private var didBootstrapSession = false
    @State private var isBootstrappingSession = false

    var body: some View {
        Group {
            if !hasCompletedOnboarding { OnboardingView(isCompleted: $hasCompletedOnboarding) }
            else if isBootstrappingSession {
                ZStack { BrandScreenBackground(); VStack(spacing: 18) { BrandMark(size: 68); ProgressView().tint(Theme.sunset); Text("Opening SnapLoop…").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) } }
            } else if session.user != nil {
                MainTabView().sheet(item: $session.pendingRoute) { route in NavigationStack { JoinEventView(route: route) { event in PendingInviteStore.clear(); session.pendingRoute = nil; session.activeEvent = event } } }
            } else { PhoneAuthFlowView() }
        }
        .task { guard hasCompletedOnboarding else { return }; await environment.config.refresh(); await bootstrapPersistedSessionIfNeeded(); await loadPendingInviteIfNeeded(); if session.user != nil { await PushNotificationClient.requestAuthorizationAndRegister() } }
        .onChange(of: hasCompletedOnboarding) { _, completed in guard completed else { return }; Task { await environment.config.refresh(); await bootstrapPersistedSessionIfNeeded(); await loadPendingInviteIfNeeded() } }
        .onChange(of: session.user?.id) { _, userId in guard userId != nil else { return }; Task { await loadPendingInviteIfNeeded(); await PushNotificationClient.requestAuthorizationAndRegister() } }
        .onChange(of: scenePhase) { _, phase in guard phase == .active, hasCompletedOnboarding else { return }; Task { await loadPendingInviteIfNeeded() } }
        .onReceive(NotificationCenter.default.publisher(for: .myPicsRoomInviteReceived)) { _ in guard hasCompletedOnboarding else { return }; Task { await loadPendingInviteIfNeeded() } }
        .onOpenURL { url in captureInvite(url) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in if let url = activity.webpageURL { captureInvite(url) } }
    }

    @MainActor private func captureInvite(_ url: URL) { if let route = DeepLinkRouter.route(for: url) { PendingInviteStore.save(route); session.pendingRoute = route } }
    @MainActor private func loadPendingInviteIfNeeded() async {
        guard session.user != nil, session.pendingRoute == nil else { return }
        if let stored = PendingInviteStore.load() { session.pendingRoute = stored; return }
        guard AppEnvironment.useLiveServices else { return }
        do { if let route = try await EventInviteClient.nextPendingRoute() { PendingInviteStore.save(route); session.pendingRoute = route } }
        catch { Log.events.error("Pending invite lookup failed: \(String(describing: error), privacy: .public)") }
    }
    @MainActor private func bootstrapPersistedSessionIfNeeded() async {
        guard !didBootstrapSession else { return }; didBootstrapSession = true
        guard session.user == nil, let uid = environment.auth.currentUserId else { return }
        isBootstrappingSession = true; defer { isBootstrappingSession = false }
        do {
            var user = try await environment.users.fetch(userId: uid)
            let stored = try await environment.faceProfiles.load(userId: uid)
            let faceProfile = stored?.version == FaceModelPolicy.currentVersion ? stored : nil
            if (faceProfile != nil) != user.hasFaceProfile { user.hasFaceProfile = faceProfile != nil; try await environment.users.save(user) }
            session.beginAuthenticatedSession(user: user, faceProfile: faceProfile)
        } catch { try? environment.auth.signOut(); session.clearAuthenticatedSession(preservePendingRoute: true) }
    }
}

struct MainTabView: View {
    @State private var selectedTab = Tab.home
    enum Tab { case home, events, gallery, you }
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(showsGreeting: true) }.tabItem { Label("Home", systemImage: "house.fill") }.tag(Tab.home)
            NavigationStack { HomeView(showsGreeting: false) }.tabItem { Label("Events", systemImage: "calendar.badge.clock") }.tag(Tab.events)
            NavigationStack { AllMyPhotosView() }.tabItem { Label("Gallery", systemImage: "photo.stack.fill") }.tag(Tab.gallery)
            NavigationStack { SettingsView() }.tabItem { Label("You", systemImage: "person.crop.circle.fill") }.tag(Tab.you)
        }.tint(Theme.sunset)
    }
}

#Preview { RootView().environmentObject(AppEnvironment.dev()).environmentObject(AppSession.dev()) }
