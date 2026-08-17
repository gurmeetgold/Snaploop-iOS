import FirebaseFunctions
import SwiftUI

struct EventDashboardView: View {
    let event: Event
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var members: [EventMember] = []
    @State private var participants: [EventParticipant] = []
    @State private var photosOfMe = 0
    @State private var sharedCount = 0
    @State private var confirmEnd = false
    @State private var confirmDelete = false
    @State private var actionError: String?
    @State private var isChangingStatus = false

    private var isOrganizer: Bool {
        members.first(where: { $0.userId == session.user?.id })?.role == .organizer
            || event.creatorUserId == session.user?.id
    }

    private var lifecycle: EventLifecycle.Status {
        EventLifecycle.status(for: event, clock: env.clock, config: env.config.current)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero

                if event.status == .deletedByOrganizer {
                    deletedNotice
                    if isOrganizer { organizerControls }
                } else {
                    syncStatusRow
                    featureGrid
                    statsRow
                    membersRow
                    if event.status == .active { invitePeopleRow }
                    if isOrganizer { organizerControls }
                }

                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(edges: .top)
        .task { await loadDashboard() }
        .confirmationDialog(
            "End this event?",
            isPresented: $confirmEnd,
            titleVisibility: .visible
        ) {
            Button("End Event", role: .destructive) {
                Task { await changeStatus { try await env.events.endEvent(id: event.id) } }
            }
        } message: {
            Text("New joins and camera syncs will stop. The organizer can reopen it while testing if the date window is still valid.")
        }
        .confirmationDialog(
            "Move this event to Deleted?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Deleted", role: .destructive) {
                Task { await changeStatus { try await env.events.moveEventToDeleted(id: event.id) } }
            }
        } message: {
            Text("This is a soft delete. The event stays recoverable in the Deleted section.")
        }
    }

    @MainActor
    private func loadDashboard() async {
        session.activeEvent = event
        if AppEnvironment.useLiveServices, event.status != .deletedByOrganizer {
            try? await syncRosterIdentities()
        }
        members = (try? await env.events.members(eventId: event.id)) ?? []
        participants = (try? await env.events.participants(eventId: event.id)) ?? []
        if let userId = session.user?.id {
            photosOfMe = ((try? await env.matches.myPhotos(eventId: event.id, userId: userId)) ?? []).count
        }
        sharedCount = ((try? await env.matches.sharedAlbum(eventId: event.id)) ?? []).count
    }

    private func syncRosterIdentities() async throws {
        let functions = Functions.functions()
        let _: Any = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Any, Error>) in
            functions.httpsCallable("syncEventRosterIdentities").call([
                "eventId": event.id
            ]) { result, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: result?.data as Any)
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Theme.violetGradient
                .overlay(Image(systemName: event.category.systemImage)
                    .font(.system(size: 80)).foregroundStyle(.white.opacity(0.15)))
                .frame(height: 220)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 6) {
                Text(event.name).font(.title).bold().foregroundStyle(.white)
                HStack(spacing: 8) {
                    Label(DateFormatting.range(event.startsAt, event.endsAt), systemImage: "calendar")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.9))
                    lifecyclePill
                    if isOrganizer {
                        Text("ORGANIZER")
                            .font(.caption2).bold()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white.opacity(0.2), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(20)
        }
        .frame(height: 220)
    }

    private var lifecyclePill: some View {
        let text: String
        switch event.status {
        case .endedByOrganizer: text = "ENDED"
        case .deletedByOrganizer: text = "DELETED"
        case .expired: text = "COMPLETED"
        case .active:
            switch lifecycle {
            case .upcoming: text = "UPCOMING"
            case .active: text = "LIVE"
            case .grace: text = "WRAPPING UP"
            case .expired: text = "COMPLETED"
            }
        }
        return Text(text).font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.25), in: Capsule())
            .foregroundStyle(.white)
    }

    private var deletedNotice: some View {
        Label("This event is in Deleted. Restore it to make it active again.", systemImage: "trash")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .padding(.horizontal)
    }

    private var syncStatusRow: some View {
        HStack {
            Label("Event Sync", systemImage: "checkmark.icloud.fill")
                .font(.subheadline).bold()
            Spacer()
            Text(EventLifecycle.canSync(event, clock: env.clock, config: env.config.current) ? "Available" : "Paused")
                .font(.subheadline)
                .foregroundStyle(EventLifecycle.canSync(event, clock: env.clock, config: env.config.current) ? .green : .secondary)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator.opacity(0.4)))
        .padding(.horizontal)
    }

    private var featureGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            NavigationLink { MyPhotosView(event: event) } label: {
                GradientTile(title: "My Photos", subtitle: "\(photosOfMe) found of you",
                             systemImage: "photo.stack.fill", gradient: Theme.coralGradient)
            }
            NavigationLink { SharedAlbumView(event: event) } label: {
                GradientTile(title: "Shared Album", subtitle: "\(sharedCount) shared previews",
                             systemImage: "person.2.fill", gradient: Theme.skyGradient)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statTile(value: "\(sharedCount)", label: "Shared Photos", icon: "photo.stack", tint: .green)
            Divider().frame(height: 36)
            statTile(value: "\(photosOfMe)", label: "Photos of You", icon: "person.fill", tint: Theme.violet)
            Divider().frame(height: 36)
            NavigationLink { SyncView(event: event) } label: {
                statTile(value: "Sync", label: "My Camera", icon: "arrow.triangle.2.circlepath", tint: Theme.sky)
            }
            .buttonStyle(.plain)
            .disabled(!EventLifecycle.canSync(event, clock: env.clock, config: env.config.current))
        }
        .padding(.vertical, 12)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator.opacity(0.4)))
        .padding(.horizontal)
    }

    private func statTile(value: String, label: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).font(.headline).foregroundStyle(Theme.ink)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var membersRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Event Members").font(.headline)
                Spacer()
                NavigationLink("View all") { ParticipantsView(event: event) }
                    .font(.subheadline)
            }
            HStack(spacing: -8) {
                ForEach(members.prefix(6)) { member in
                    ZStack {
                        Circle().fill(Theme.violetGradient)
                        Text(initial(for: member))
                            .font(.caption).bold().foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                }
                if members.count > 6 {
                    ZStack {
                        Circle().fill(Color(.systemGray4))
                        Text("+\(members.count - 6)").font(.caption2).bold()
                    }
                    .frame(width: 36, height: 36)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                }
            }
        }
        .padding(.horizontal)
    }

    private var invitePeopleRow: some View {
        NavigationLink {
            ShareEventView(event: event)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.plus")
                    .font(.title3).foregroundStyle(Theme.coral)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invite People").font(.headline).foregroundStyle(Theme.ink)
                    Text("Share code, link, QR, or invite by phone")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private func initial(for member: EventMember) -> String {
        if member.userId == session.user?.id {
            if let myName = session.user?.displayName, let first = myName.first { return String(first).uppercased() }
            if let phone = session.user?.phoneNumber { return String(phone.suffix(2)) }
        }
        if let participant = participants.first(where: { $0.userId == member.userId }) {
            if let name = participant.displayName, let first = name.first { return String(first).uppercased() }
            if let phone = participant.phoneNumber { return String(phone.suffix(2)) }
        }
        return "?"
    }

    private var organizerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Organizer Controls").font(.subheadline).bold().foregroundStyle(.secondary)

            if event.status == .endedByOrganizer {
                Button {
                    Task { await changeStatus { try await env.events.reopenEvent(id: event.id) } }
                } label: {
                    Label("Reopen Event", systemImage: "arrow.counterclockwise.circle")
                }
                .disabled(isChangingStatus)
            }

            if event.status == .deletedByOrganizer {
                Button {
                    Task { await changeStatus { try await env.events.restoreEvent(id: event.id) } }
                } label: {
                    Label("Restore Event", systemImage: "arrow.uturn.backward.circle")
                }
                .disabled(isChangingStatus)
            } else {
                if event.status == .active {
                    Button(role: .destructive) { confirmEnd = true } label: {
                        Label("End Event", systemImage: "stop.circle")
                    }
                    .disabled(isChangingStatus)
                }

                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Move to Deleted", systemImage: "trash")
                }
                .disabled(isChangingStatus)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator.opacity(0.4)))
        .padding(.horizontal)
    }

    @MainActor
    private func changeStatus(_ operation: @escaping () async throws -> Void) async {
        isChangingStatus = true
        actionError = nil
        defer { isChangingStatus = false }
        do {
            try await operation()
            session.activeEvent = nil
            dismiss()
        } catch {
            actionError = (error as NSError).localizedDescription
        }
    }
}
