import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published var events: [Event] = []
    @Published var isLoading = false

    private var env: AppEnvironment?
    private var session: AppSession?
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        isLoading = true; defer { isLoading = false }
        events = (try? await env.events.events(forUserId: userId)) ?? []
    }

    /// Total matched photos of the user across every joined event — the Home
    /// insight banner's headline number.
    func totalPhotosOfMe() async -> Int {
        guard let env, let userId = session?.user?.id else { return 0 }
        var total = 0
        for event in events {
            total += ((try? await env.matches.myPhotos(eventId: event.id, userId: userId)) ?? []).count
        }
        return total
    }
}

/// Home: the trip list, plus (when `showsGreeting`) the greeting header,
/// Create/Join cards, and an insight banner — matching the product's Home
/// screen. The Trips tab reuses this same view with the greeting section
/// collapsed, so there's exactly one source of truth for "your trips".
struct HomeView: View {
    var showsGreeting: Bool = true

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = HomeModel()
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var joinRoute: DeepLinkRoute?
    @State private var photosOfMe = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if showsGreeting {
                    greeting
                    createJoinRow
                    if !model.events.isEmpty {
                        InsightBanner(value: "\(photosOfMe)", label: "photos found of you", systemImage: "sparkles")
                    }
                }

                HStack {
                    Text(showsGreeting ? "Your Trips" : "All Trips").font(.title3).bold()
                    Spacer()
                }
                .padding(.horizontal)

                if model.events.isEmpty {
                    emptyState.padding(.horizontal)
                } else {
                    VStack(spacing: 12) {
                        ForEach(model.events) { event in
                            NavigationLink {
                                EventDashboardView(event: event)
                            } label: {
                                TripCard(event: event)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { session.activeEvent = event })
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(showsGreeting ? "" : "Trips")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !showsGreeting {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showCreate = true } label: { Label("Create Trip", systemImage: "plus") }
                        Button { showJoin = true } label: { Label("Join with Code", systemImage: "qrcode.viewfinder") }
                    } label: { Image(systemName: "plus.circle.fill") }
                }
            }
        }
        .task {
            model.configure(env: env, session: session)
            await model.reload()
            photosOfMe = await model.totalPhotosOfMe()
        }
        .refreshable {
            await model.reload()
            photosOfMe = await model.totalPhotosOfMe()
        }
        .sheet(isPresented: $showCreate) {
            CreateEventView { event in
                session.activeEvent = event
                Task { await model.reload() }
            }
        }
        .sheet(isPresented: $showJoin) {
            EnterCodeView { route in showJoin = false; joinRoute = route }
        }
        .sheet(item: $joinRoute) { route in
            NavigationStack {
                JoinEventView(route: route) { event in
                    joinRoute = nil; session.activeEvent = event
                    Task { await model.reload() }
                }
            }
        }
    }

    private var greeting: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hi, \(session.user?.displayName ?? "there")! 👋")
                    .font(.title2).bold().foregroundStyle(Theme.ink)
                Text("Get every photo of you from the event, automatically.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private var createJoinRow: some View {
        HStack(spacing: 12) {
            Button { showCreate = true } label: {
                actionCard(title: "Create Trip", subtitle: "Start a new adventure",
                          icon: "plus", gradient: Theme.coralGradient)
            }
            Button { showJoin = true } label: {
                actionCard(title: "Join Trip", subtitle: "Enter a trip code",
                          icon: "person.2.fill", gradient: Theme.skyGradient)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private func actionCard(title: String, subtitle: String, icon: String, gradient: LinearGradient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.25)).frame(width: 36, height: 36)
                Image(systemName: icon).foregroundStyle(.white)
            }
            Text(title).font(.subheadline).bold().foregroundStyle(.white)
            Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.85))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(gradient, in: RoundedRectangle(cornerRadius: Theme.tileRadius))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("You're not in any trips yet.").font(.headline)
            Text("Create a trip for your event, or join one with a code.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

/// A trip row card: cover image, name, status pill, dates, participant avatars.
private struct TripCard: View {
    let event: Event
    @EnvironmentObject private var env: AppEnvironment

    private var status: EventLifecycle.Status {
        EventLifecycle.status(for: event, clock: env.clock, config: env.config.current)
    }
    private var statusLabel: String {
        switch status {
        case .upcoming: return "UPCOMING"
        case .active: return "LIVE"
        case .grace: return "WRAPPING UP"
        case .expired: return "COMPLETED"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Theme.violetGradient
                Image(systemName: event.category.systemImage)
                    .font(.title2).foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.name).font(.headline).foregroundStyle(Theme.ink)
                    StatusPill(text: statusLabel, tint: Theme.tint(for: status))
                }
                Label(DateFormatting.range(event.startsAt, event.endsAt), systemImage: "calendar")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator.opacity(0.4)))
    }
}

/// Manual "Enter Code" entry (the secondary in-person join path).
struct EnterCodeView: View {
    let onResolved: (DeepLinkRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Enter trip code or link") {
                    TextField("e.g. ABC-234", text: $text)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Join Trip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        if let route = DeepLinkRouter.route(forManualEntry: text) {
                            onResolved(route)
                        } else {
                            error = AppError.invalidJoinCode.userMessage
                        }
                    }.disabled(text.isEmpty)
                }
            }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppEnvironment.dev())
        .environmentObject(AppSession.dev())
}
