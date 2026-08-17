import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published var events: [Event] = []
    @Published var rolesByEventId: [String: EventMember.Role] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var env: AppEnvironment?
    private var session: AppSession?
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await env.events.events(forUserId: userId)
            var roles: [String: EventMember.Role] = [:]
            for event in loaded {
                if let mine = try? await env.events.members(eventId: event.id).first(where: { $0.userId == userId }) {
                    roles[event.id] = mine.role
                } else if event.creatorUserId == userId {
                    roles[event.id] = .organizer
                }
            }
            events = loaded
            rolesByEventId = roles
            errorMessage = nil
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    func restore(_ event: Event) async {
        guard let env else { return }
        do {
            try await env.events.restoreEvent(id: event.id)
            await reload()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    func totalPhotosOfMe() async -> Int {
        guard let env, let userId = session?.user?.id else { return 0 }
        var total = 0
        for event in activeEvents {
            total += ((try? await env.matches.myPhotos(eventId: event.id, userId: userId)) ?? []).count
        }
        return total
    }

    var activeEvents: [Event] { events.filter { $0.status != .archived } }
    var archivedEvents: [Event] { events.filter { $0.status == .archived } }
}

struct HomeView: View {
    var showsGreeting: Bool = true

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = HomeModel()
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var joinRoute: DeepLinkRoute?
    @State private var pendingJoinRoute: DeepLinkRoute?
    @State private var photosOfMe = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if showsGreeting {
                    greeting
                    createJoinRow
                    if !model.activeEvents.isEmpty {
                        InsightBanner(value: "\(photosOfMe)", label: "photos found of you", systemImage: "sparkles")
                    }
                }

                HStack {
                    Text(showsGreeting ? "Your Events" : "All Events").font(.title3).bold()
                    Spacer()
                }
                .padding(.horizontal)

                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }

                if model.activeEvents.isEmpty {
                    emptyState.padding(.horizontal)
                } else {
                    VStack(spacing: 12) {
                        ForEach(model.activeEvents) { event in
                            NavigationLink {
                                EventDashboardView(event: event)
                            } label: {
                                EventCard(event: event, role: model.rolesByEventId[event.id])
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { session.activeEvent = event })
                        }
                    }
                    .padding(.horizontal)
                }

                if !model.archivedEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Deleted").font(.headline).foregroundStyle(.secondary)
                        ForEach(model.archivedEvents) { event in
                            HStack(spacing: 12) {
                                Image(systemName: "trash").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.name).font(.subheadline).bold()
                                    Text("Soft-deleted • data retained")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Restore") { Task { await model.restore(event) } }
                                    .buttonStyle(.bordered)
                            }
                            .padding(12)
                            .background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                        }
                    }
                    .padding(.horizontal)
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
        .sheet(isPresented: $showJoin, onDismiss: {
            if let route = pendingJoinRoute {
                pendingJoinRoute = nil
                DispatchQueue.main.async { joinRoute = route }
            }
        }) {
            EnterCodeView { route in
                pendingJoinRoute = route
                showJoin = false
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

    private var greeting: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hi, \(session.user?.displayName ?? "there")! 👋")
                    .font(.title2).bold().foregroundStyle(Theme.ink)
                Text("Find the photos you're in from every shared event.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private var createJoinRow: some View {
        HStack(spacing: 12) {
            Button { showCreate = true } label: {
                actionCard(title: "Create Event", subtitle: "Trip, party, family & more",
                           icon: "plus", gradient: Theme.coralGradient)
            }
            Button { showJoin = true } label: {
                actionCard(title: "Join Event", subtitle: "Enter an invite code",
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
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No active events yet.").font(.headline)
            Text("Create an event or join one with an invite code.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32)
    }
}

private struct EventCard: View {
    let event: Event
    let role: EventMember.Role?
    @EnvironmentObject private var env: AppEnvironment

    private var statusLabel: String {
        if event.status == .endedByOrganizer { return "ENDED" }
        if event.status == .expired { return "COMPLETED" }
        switch EventLifecycle.status(for: event, clock: env.clock, config: env.config.current) {
        case .upcoming: return "UPCOMING"
        case .active: return "LIVE"
        case .grace: return "WRAPPING UP"
        case .expired: return "COMPLETED"
        }
    }

    private var roleLabel: String {
        switch role {
        case .organizer: return "ORGANIZER"
        case .participant: return "MEMBER"
        case .none: return event.creatorUserId.isEmpty ? "MEMBER" : "MEMBER"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Theme.violetGradient
                Image(systemName: event.category.systemImage).font(.title2).foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 5) {
                Text(event.name).font(.headline).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(spacing: 6) {
                    Text(roleLabel).font(.caption2).bold().foregroundStyle(Theme.violet)
                    Text("•").foregroundStyle(.tertiary)
                    Text(statusLabel).font(.caption2).bold().foregroundStyle(.green)
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
                Section("Enter event code or invite link") {
                    TextField("e.g. HHD-4RW", text: $text)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Join Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        if let route = DeepLinkRouter.route(forManualEntry: text) {
                            error = nil
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
    RootView().environmentObject(AppEnvironment.dev()).environmentObject(AppSession.dev())
}
