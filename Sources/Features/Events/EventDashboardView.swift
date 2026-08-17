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
    @State private var confirmArchive = false
    @State private var confirmLeave = false
    @State private var actionError: String?

    private var myRole: EventMember.Role? {
        members.first(where: { $0.userId == session.user?.id })?.role
    }
    private var isOrganizer: Bool { myRole == .organizer || event.creatorUserId == session.user?.id }
    private var lifecycle: EventLifecycle.Status {
        EventLifecycle.status(for: event, clock: env.clock, config: env.config.current)
    }
    private var canReopenEndedEvent: Bool {
        isOrganizer && event.status == .endedByOrganizer && lifecycle != .expired
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                syncStatusRow
                featureGrid
                statsRow
                membersRow
                if event.status == .active { invitePeopleRow }
                managementControls
                if let actionError {
                    Text(actionError).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
            }
            .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(edges: .top)
        .task { await load() }
        .confirmationDialog("Move this event to Deleted?", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Move to Deleted", role: .destructive) { Task { await archive() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This is a soft delete. Event data is retained and the event can be restored from the Deleted section.")
        }
        .confirmationDialog("Leave this event?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave Event", role: .destructive) { Task { await leave() } }
            Button("Cancel", role: .cancel) { }
        }
    }

    @MainActor
    private func load() async {
        session.activeEvent = event
        if AppEnvironment.useLiveServices { try? await syncRosterIdentities() }
        members = (try? await env.events.members(eventId: event.id)) ?? []
        participants = (try? await env.events.participants(eventId: event.id)) ?? []
        if let userId = session.user?.id {
            photosOfMe = ((try? await env.matches.myPhotos(eventId: event.id, userId: userId)) ?? []).count
        }
        sharedCount = ((try? await env.matches.sharedAlbum(eventId: event.id)) ?? []).count
    }

    private func syncRosterIdentities() async throws {
        let _: Any = try await withCheckedThrowingContinuation { continuation in
            Functions.functions().httpsCallable("syncEventRosterIdentities").call(["eventId": event.id]) { result, error in
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
            VStack(alignment: .leading, spacing: 7) {
                Text(event.name).font(.title).bold().foregroundStyle(.white)
                HStack(spacing: 8) {
                    Text(isOrganizer ? "ORGANIZER" : "MEMBER")
                        .font(.caption2).bold().padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.25), in: Capsule()).foregroundStyle(.white)
                    lifecyclePill
                }
                Label(DateFormatting.range(event.startsAt, event.endsAt), systemImage: "calendar")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.9))
            }
            .padding(20)
        }
        .frame(height: 220)
    }

    private var lifecyclePill: some View {
        let text: String
        if event.status == .endedByOrganizer { text = "ENDED" }
        else if event.status == .expired { text = "COMPLETED" }
        else {
            switch lifecycle {
            case .upcoming: text = "UPCOMING"
            case .active: text = "LIVE"
            case .grace: text = "WRAPPING UP"
            case .expired: text = "COMPLETED"
            }
        }
        return Text(text).font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.25), in: Capsule()).foregroundStyle(.white)
    }

    private var syncStatusRow: some View {
        HStack {
            Label("Camera matching", systemImage: "checkmark.icloud.fill").font(.subheadline).bold()
            Spacer()
            Text(EventLifecycle.canSync(event, clock: env.clock, config: env.config.current) ? "Ready" : "Closed")
                .font(.subheadline).foregroundStyle(.secondary)
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
                GradientTile(title: "Shared Photos", subtitle: "\(sharedCount) matched photos",
                             systemImage: "person.2.fill", gradient: Theme.skyGradient)
            }
        }
        .buttonStyle(.plain).padding(.horizontal)
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statTile(value: "\(sharedCount)", label: "Shared", icon: "photo.stack", tint: .green)
            Divider().frame(height: 36)
            statTile(value: "\(photosOfMe)", label: "Of You", icon: "person.fill", tint: Theme.violet)
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
        }.frame(maxWidth: .infinity)
    }

    private var membersRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Event Members").font(.headline)
                Spacer()
                NavigationLink("View all") { ParticipantsView(event: event) }.font(.subheadline)
            }
            HStack(spacing: -8) {
                ForEach(members.prefix(6)) { member in
                    ZStack {
                        Circle().fill(Theme.violetGradient)
                        Text(initial(for: member)).font(.caption).bold().foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36).overlay(Circle().strokeBorder(.background, lineWidth: 2))
                }
            }
        }.padding(.horizontal)
    }

    private var invitePeopleRow: some View {
        NavigationLink { ShareEventView(event: event) } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.plus").font(.title3).foregroundStyle(Theme.coral)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invite People").font(.headline).foregroundStyle(Theme.ink)
                    Text("Share link, code, QR, or invite by phone")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14).background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator.opacity(0.4)))
        }
        .buttonStyle(.plain).padding(.horizontal)
    }

    private var managementControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isOrganizer ? "Organizer Controls" : "Membership")
                .font(.subheadline).bold().foregroundStyle(.secondary)
            if isOrganizer {
                if canReopenEndedEvent {
                    Button { Task { await reopen() } } label: {
                        Label("Reopen Event", systemImage: "arrow.counterclockwise.circle")
                    }
                }
                Button(role: .destructive) { confirmArchive = true } label: {
                    Label("Move Event to Deleted", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) { confirmLeave = true } label: {
                    Label("Leave Event", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator.opacity(0.4)))
        .padding(.horizontal)
    }

    private func initial(for member: EventMember) -> String {
        if let participant = participants.first(where: { $0.userId == member.userId }) {
            if let name = participant.displayName, let first = name.first { return String(first).uppercased() }
            if let phone = participant.phoneNumber { return String(phone.suffix(2)) }
        }
        return "?"
    }

    @MainActor
    private func reopen() async {
        do {
            try await env.events.restoreEvent(id: event.id)
            actionError = "Event reopened. Go back and reopen it to refresh the screen."
        } catch { actionError = (error as NSError).localizedDescription }
    }

    @MainActor
    private func archive() async {
        do {
            try await env.events.archiveEvent(id: event.id)
            if session.activeEvent?.id == event.id { session.activeEvent = nil }
            dismiss()
        } catch { actionError = (error as NSError).localizedDescription }
    }

    @MainActor
    private func leave() async {
        guard let userId = session.user?.id else { return }
        do {
            try await env.events.removeMember(eventId: event.id, userId: userId)
            if session.activeEvent?.id == event.id { session.activeEvent = nil }
            dismiss()
        } catch { actionError = (error as NSError).localizedDescription }
    }
}
