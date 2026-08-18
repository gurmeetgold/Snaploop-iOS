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

    private var visibleEvents: [Event] { model.events.filter { $0.status != .deletedByOrganizer } }
    private var deletedEvents: [Event] { model.events.filter { $0.status == .deletedByOrganizer } }

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if showsGreeting {
                        greeting
                        createJoinRow
                        if !visibleEvents.isEmpty {
                            InsightBanner(value: "\(photosOfMe)", label: "photos found of you", systemImage: "sparkles")
                                .padding(.horizontal)
                        }
                    }

                    sectionHeader(showsGreeting ? "Your Events" : "All Events")

                    if visibleEvents.isEmpty { emptyState.padding(.horizontal) }
                    else { eventList(visibleEvents) }

                    if !deletedEvents.isEmpty {
                        sectionHeader("Deleted")
                        eventList(deletedEvents)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(showsGreeting ? "" : "Events")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !showsGreeting {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showCreate = true } label: { Label("Create Event", systemImage: "plus") }
                        Button { showJoin = true } label: { Label("Join with Code", systemImage: "qrcode.viewfinder") }
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Theme.brandGradient, in: Circle())
                    }
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
            Text(title).font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.horizontal)
    }

    private func eventList(_ events: [Event]) -> some View {
        VStack(spacing: 12) {
            ForEach(events) { event in
                NavigationLink { EventDashboardView(event: event) } label: {
                    EventCard(event: event, currentUserId: session.user?.id)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { session.activeEvent = event })
            }
        }
        .padding(.horizontal)
    }

    private var greeting: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Hi, \(session.user?.displayName ?? "there") 👋")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Text("Your moments, found from everyone’s camera.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            BrandMark(size: 46)
        }
        .padding(.horizontal)
    }

    private var createJoinRow: some View {
        HStack(spacing: 12) {
            Button { showCreate = true } label: {
                actionCard(title: "Create Event", subtitle: "Party, trip, family & more", icon: "plus", gradient: Theme.sunsetGradient)
            }
            Button { showJoin = true } label: {
                actionCard(title: "Join Event", subtitle: "Code, link or QR", icon: "person.2.fill", gradient: Theme.socialGradient)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private func actionCard(title: String, subtitle: String, icon: String, gradient: LinearGradient) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.white.opacity(0.22))
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            Spacer(minLength: 4)
            Text(title).font(.headline).foregroundStyle(.white)
            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.88))
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(gradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.10), radius: 16, y: 8)
    }

    private var emptyState: some View {
        PremiumCard {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.peach.opacity(0.25))
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 34)).foregroundStyle(Theme.sunset)
                }
                .frame(width: 74, height: 74)
                Text("No events yet").font(.headline)
                Text("Create an event, or join one with a code, link or QR.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

private struct EventCard: View {
    let event: Event
    let currentUserId: String?
    @EnvironmentObject private var env: AppEnvironment

    private var lifecycle: EventLifecycle.Status { EventLifecycle.status(for: event, clock: env.clock, config: env.config.current) }
    private var roleLabel: String { event.creatorUserId == currentUserId ? "ORGANIZER" : "MEMBER" }

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
        HStack(spacing: 14) {
            ZStack {
                Theme.violetGradient
                Image(systemName: event.category.systemImage)
                    .font(.title2).foregroundStyle(.white)
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(event.name).font(.headline).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(spacing: 7) {
                    Label(roleLabel, systemImage: event.creatorUserId == currentUserId ? "crown.fill" : "person.fill")
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                    StatusPill(text: statusLabel, tint: statusTint)
                }
                Label(DateFormatting.range(event.startsAt, event.endsAt), systemImage: "calendar")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
        }
        .padding(14)
        .background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.separator.opacity(0.20)))
        .shadow(color: Theme.ink.opacity(0.055), radius: 14, y: 7)
    }
}

struct EnterCodeView: View {
    let onResolved: (DeepLinkRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BrandScreenBackground()
                VStack(spacing: 20) {
                    BrandMark(size: 62)
                    Text("Join an Event").font(.title2.bold())
                    TextField("Event code or invite link", text: $text)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    Button {
                        if let route = DeepLinkRouter.route(forManualEntry: text) { onResolved(route) }
                        else { error = AppError.invalidJoinCode.userMessage }
                    } label: {
                        Label("Continue", systemImage: "arrow.right.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 18))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(24)
            }
            .navigationTitle("Join Event")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

#Preview {
    RootView().environmentObject(AppEnvironment.dev()).environmentObject(AppSession.dev())
}
