import SwiftUI

/// Top-level router: shows the phone/OTP sign-in flow until `session.user` is
/// set, then the 5-tab shell. Inbound invite links/QR are captured into a
/// pending route regardless of auth state, and replayed as a join sheet once
/// the user is signed in — this is what makes deferred deep linking "land on
/// Join" after a fresh install + sign-in.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var session: AppSession

    var body: some View {
        Group {
            if session.user != nil {
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
        .onOpenURL { url in
            if let route = DeepLinkRouter.route(for: url) { session.pendingRoute = route }
        }
    }
}

/// The signed-in shell: a 5-tab bar (Home / Trips / Shared / Requests / You),
/// matching the product's visual language. Shared and Requests are scoped to
/// `session.activeEvent` — the trip currently in focus, set when the user opens
/// one from Home or Trips (mirrors the "current trip" switcher in the designs).
struct MainTabView: View {
    @State private var selectedTab = Tab.home

    enum Tab { case home, trips, shared, requests, you }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(showsGreeting: true) }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            NavigationStack { HomeView(showsGreeting: false) }
                .tabItem { Label("Trips", systemImage: "suitcase.fill") }
                .tag(Tab.trips)

            NavigationStack { ActiveEventScopedView(kind: .shared) }
                .tabItem { Label("Shared", systemImage: "person.2.fill") }
                .tag(Tab.shared)

            NavigationStack { ActiveEventScopedView(kind: .requests) }
                .tabItem { Label("Requests", systemImage: "bell.fill") }
                .tag(Tab.requests)

            NavigationStack { SettingsView() }
                .tabItem { Label("You", systemImage: "person.crop.circle.fill") }
                .tag(Tab.you)
        }
        .tint(Theme.coral)
    }
}

/// Renders the Shared or Requests tab content for whichever event is active,
/// with a friendly prompt to pick one if nothing is active yet.
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
