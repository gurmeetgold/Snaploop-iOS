import SwiftUI

private enum CachedEventList {
    private static func key(userId: String) -> String { "snaploop.events.cache.\(userId)" }

    static func load(userId: String) -> [Event] {
        guard let data = UserDefaults.standard.data(forKey: key(userId: userId)),
              let events = try? JSONDecoder().decode([Event].self, from: data) else { return [] }
        return events
    }

    static func save(_ events: [Event], userId: String) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: key(userId: userId))
    }
}

@MainActor
final class HomeModel: ObservableObject {
    @Published var events: [Event] = []
    @Published var rolesByEventId: [String: EventMember.Role] = [:]
    @Published var notifications: [EventNotification] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    private var env: AppEnvironment?
    private var session: AppSession?

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
        if let userId = session.user?.id, events.isEmpty {
            events = CachedEventList.load(userId: userId)
            for event in events where event.creatorUserId == userId {
                rolesByEventId[event.id] = .organizer
            }
        }
    }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        isLoading = true
        errorMessage = nil

        do {
            let refreshed = try await env.events.events(forUserId: userId)
            events = refreshed
            CachedEventList.save(refreshed, userId: userId)

            var resolvedRoles: [String: EventMember.Role] = [:]
            for event in refreshed {
                if event.creatorUserId == userId {
                    resolvedRoles[event.id] = .organizer
                    continue
                }
                if let roster = try? await env.events.members(eventId: event.id),
                   let role = roster.first(where: { $0.userId == userId })?.role {
                    resolvedRoles[event.id] = role
                }
            }
            rolesByEventId = resolvedRoles
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }

        notifications = (try? await EventNotificationClient.unread(userId: userId)) ?? notifications
        isLoading = false
    }

    func dismissNotification(_ notification: EventNotification) async {
        guard let userId = session?.user?.id else { return }
        notifications.removeAll { $0.id == notification.id }
        try? await EventNotificationClient.markRead(userId: userId, notificationId: notification.id)
    }
}

struct HomeView: View {
    var showsGreeting: Bool = true
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = HomeModel()
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showAllUpdates = false
    @State private var joinRoute: DeepLinkRoute?

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
                        if !model.notifications.isEmpty {
                            updatesSection
                        }
                    }
                    sectionHeader(showsGreeting ? "Your Events" : "All Events")
                    if visibleEvents.isEmpty {
                        if model.isLoading {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 36)
                        } else {
                            emptyState.padding(.horizontal)
                        }
                    } else {
                        eventList(visibleEvents)
                    }
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
                        Button { showJoin = true } label: { Label("Join Event", systemImage: "qrcode.viewfinder") }
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Theme.socialGradient, in: Circle())
                    }
                }
            }
        }
        .task {
            model.configure(env: env, session: session)
            await model.reload()
        }
        .refreshable { await model.reload() }
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
        .sheet(isPresented: $showAllUpdates) {
            NavigationStack {
                ZStack {
                    BrandScreenBackground()
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.notifications) { notification in
                                eventNotificationCard(notification)
                            }
                        }
                        .padding(16)
                    }
                }
                .navigationTitle("Updates")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showAllUpdates = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
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

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Updates")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if model.notifications.count > 1 {
                    Button {
                        showAllUpdates = true
                    } label: {
                        HStack(spacing: 5) {
                            Text("View all")
                            Text("\(model.notifications.count)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.violet.opacity(0.12), in: Capsule())
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.violet)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            if let latest = model.notifications.first {
                eventNotificationCard(latest)
                    .padding(.horizontal)
            }
        }
    }

    private func eventNotificationCard(_ notification: EventNotification) -> some View {
        PremiumCard {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Theme.mint.opacity(0.14))
                    Image(systemName: "bell.fill").foregroundStyle(Theme.mint)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(notification.title).font(.subheadline.bold()).foregroundStyle(Theme.ink)
                    Text(notification.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                Button { Task { await model.dismissNotification(notification) } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss update")
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
                    EventCard(
                        event: event,
                        currentUserId: session.user?.id,
                        role: model.rolesByEventId[event.id]
                    )
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
                Text("Photos your friends took of you on their phones, brought to your phone automatically.")
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
                actionCard(title: "Create Event", subtitle: "Trip, party, family & more", icon: "plus", gradient: Theme.brandGradient)
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
                RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.20))
                Image(systemName: icon).font(.headline).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            Spacer(minLength: 4)
            Text(title).font(.headline).foregroundStyle(.white)
            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.90))
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(gradient, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color.black.opacity(0.14), radius: 16, y: 8)
    }

    private var emptyState: some View {
        PremiumCard {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.lilac.opacity(0.14))
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.lilac)
                }
                .frame(width: 74, height: 74)
                Text("No Events yet").font(.headline).foregroundStyle(Theme.ink)
                Text("Create an Event, or join one with a code, link or QR.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

private struct EventCard: View {
    let event: Event
    let currentUserId: String?
    let role: EventMember.Role?
    @EnvironmentObject private var env: AppEnvironment

    private var lifecycle: EventLifecycle.Status {
        EventLifecycle.status(for: event, clock: env.clock, config: env.config.current)
    }

    private var effectiveRole: EventMember.Role {
        if event.creatorUserId == currentUserId { return .organizer }
        return role ?? .participant
    }

    private var roleLabel: String { effectiveRole.displayName.uppercased() }

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
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 6) {
                Text(event.name)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                Label(
                    roleLabel,
                    systemImage: effectiveRole == .organizer ? "crown.fill" : effectiveRole == .admin ? "shield.fill" : "person.fill"
                )
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)

                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(DateFormatting.range(event.startsAt, event.endsAt))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 10) {
                StatusPill(text: statusLabel, tint: statusTint)
                    .fixedSize(horizontal: true, vertical: true)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.divider)
        }
        .shadow(color: Color.black.opacity(0.09), radius: 14, y: 7)
    }
}

struct EnterCodeView: View {
    let onResolved: (DeepLinkRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var showQRScanner = false

    var body: some View {
        NavigationStack {
            ZStack {
                BrandScreenBackground()
                VStack(spacing: 18) {
                    Spacer().frame(height: 70)
                    BrandMark(size: 62)
                    Text("Join an Event").font(.title2.bold()).foregroundStyle(Theme.ink)
                    Text("Enter an Event code or invite link, or scan the Event QR code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    TextField("Event code or invite link", text: $text)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding()
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }

                    Button {
                        resolve(text)
                    } label: {
                        Label("Continue", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Theme.socialGradient, in: RoundedRectangle(cornerRadius: 18))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    HStack {
                        Rectangle().fill(Theme.divider).frame(height: 1)
                        Text("or").font(.caption).foregroundStyle(.secondary)
                        Rectangle().fill(Theme.divider).frame(height: 1)
                    }

                    Button { showQRScanner = true } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.violet)
                    .background(Theme.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))

                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Join Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRCodeScannerSheet { value in
                    resolve(value)
                }
            }
        }
    }

    private func resolve(_ value: String) {
        if let route = DeepLinkRouter.route(forManualEntry: value) {
            error = nil
            onResolved(route)
        } else {
            error = "That QR code, Event code, or invite link isn't valid."
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppEnvironment.dev())
        .environmentObject(AppSession.dev())
}
