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

    func totalPhotosOfMe() async -> Int {
        guard let env, let userId = session?.user?.id else { return 0 }
        var total = 0
        for event in events where event.status != .deletedByOrganizer {
            total += ((try? await env.matches.myPhotos(eventId: event.id, userId: userId)) ?? []).count
        }
        return total
    }
}

struct HomeView: View {
    var showsGreeting: Bool = true

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = HomeModel()
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var joinRoute: DeepLinkRoute?
    @State private var photosOfMe = 0

    private var visibleEvents: [Event] {
        model.events.filter { $0.status != .deletedByOrganizer }
    }

    private var deletedEvents: [Event] {
        model.events.filter { $0.status == .deletedByOrganizer }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if showsGreeting {
                    greeting
                    createJoinRow
                    if !visibleEvents.isEmpty {
                        InsightBanner(value: "\(photosOfMe)", label: "photos found of you", systemImage: "sparkles")
                    }
                }

                sectionHeader(showsGreeting ? "Your Events" : "All Events")

                if visibleEvents.isEmpty {
                    emptyState.padding(.horizontal)
                } else {
                    eventList(visibleEvents)
                }

                if !deletedEvents.isEmpty {
                    sectionHeader("Deleted")
                    eventList(deletedEvents)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(showsGreeting ? "" : "Events")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !showsGreeting {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showCreate = true } label: { Label("Create Event", systemImage: "plus") }
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
            EnterCodeView { route in
                showJoin = false
                joinRoute = route
            }
        }
        .sheet(item: $joinRoute) { route in
            NavigationStack {
                JoinEventView(route: route) { event in
                    joinRoute = nil
                    session.activeEvent = event
                    Task { await model.reload() }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.title3).bold()
            Spacer()
        }
        .padding(.horizontal)
    }

    private func eventList(_ events: [Event]) -> some View {
        VStack(spacing: 12) {
            ForEach(events) { event in
                NavigationLink {
                    EventDashboardView(event: event)
                } label: {
                    EventCard(event: event, currentUserId: session.user?.id)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { session.activeEvent = event })
            }
        }
        .padding(.horizontal)
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
                actionCard(title: "Create Event", subtitle: "Party, trip, family & more",
                           icon: "plus", gradient: Theme.coralGradient)
            }
            Button { showJoin = true } label: {
                actionCard(title: "Join Event", subtitle: "Enter an event code",
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
            Text("You're not in any events yet.").font(.headline)
            Text("Create an event, or join one with a code.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

private struct EventCard: View {
    let event: Event
    let currentUserId: String?
    @EnvironmentObject private var env: AppEnvironment

    private var lifecycle: EventLifecycle.Status {
        EventLifecycle.status(for: event, clock: env.clock, config: env.config.current)
    }

    private var roleLabel: String {
        event.creatorUserId == currentUserId ? "ORGANIZER" : "MEMBER"
    }

    private var statusLabel: String {
        switch event.status {
        case .endedByOrganizer: return "ENDED"
        case .deletedByOrganizer: return "DELETED"
        case .expired: return "COMPLETED"
        case .active:
            switch lifecycle {
            case .upcoming: return "UPCOMING"
            case .active: return "LIVE"
            case .grace: return "WRAPPING UP"
            case .expired: return "COMPLETED"
            }
        }
    }

    private var statusTint: Color {
        switch event.status {
        case .endedByOrganizer, .deletedByOrganizer, .expired: return .gray
        case .active: return Theme.tint(for: lifecycle)
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

            VStack(alignment: .leading, spacing: 5) {
                Text(event.name).font(.headline).foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    Text(roleLabel)
                        .font(.caption2).bold().foregroundStyle(.secondary)
                    StatusPill(text: statusLabel, tint: statusTint)
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

struct EnterCodeView: View {
    let onResolved: (DeepLinkRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Enter event code or link") {
                    TextField("e.g. ABC-234", text: $text)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Join Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        if let route = DeepLinkRouter.route(forManualEntry: text) {
                            onResolved(route)
                        } else {
                            error = AppError.invalidJoinCode.userMessage
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
