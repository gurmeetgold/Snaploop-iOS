import FirebaseFunctions
import SwiftUI

struct EventDashboardView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var currentEvent: Event
    @State private var members: [EventMember] = []
    @State private var participants: [EventParticipant] = []
    @State private var sharedMatches: [PhotoMatch] = []
    @State private var photosOfMe = 0
    @State private var sharedCount = 0
    @State private var confirmEnd = false
    @State private var confirmDelete = false
    @State private var actionError: String?
    @State private var isChangingStatus = false

    init(event: Event) {
        _currentEvent = State(initialValue: event)
    }

    private var currentUserRole: EventMember.Role? {
        guard let userId = session.user?.id else { return nil }
        if currentEvent.creatorUserId == userId { return .organizer }
        return members.first(where: { $0.userId == userId })?.role
    }

    private var isOrganizer: Bool { currentUserRole == .organizer }
    private var canManageMembers: Bool { currentUserRole?.canManageMembers == true }

    private var lifecycle: EventLifecycle.Status {
        EventLifecycle.status(for: currentEvent, clock: env.clock, config: env.config.current)
    }

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero

                    if currentEvent.status == .deletedByOrganizer {
                        deletedNotice
                        if isOrganizer { organizerControls }
                    } else {
                        syncStatusRow
                        featureGrid
                        statsRow
                        membersRow
                        if currentEvent.status == .active && canManageMembers { invitePeopleRow }
                        if isOrganizer { organizerControls }
                    }

                    if let actionError {
                        Label(actionError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDashboard() }
        .confirmationDialog("End this event?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End Event", role: .destructive) {
                Task { await changeStatus { try await env.events.endEvent(id: currentEvent.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New joins and camera syncs will stop.")
        }
        .confirmationDialog("Move this event to Deleted?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move to Deleted", role: .destructive) {
                Task { await changeStatus { try await env.events.moveEventToDeleted(id: currentEvent.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is a soft delete. The event stays recoverable in the Deleted section.")
        }
    }

    @MainActor
    private func loadDashboard() async {
        session.activeEvent = currentEvent
        if AppEnvironment.useLiveServices, currentEvent.status != .deletedByOrganizer {
            try? await syncRosterIdentities()
        }
        members = (try? await env.events.members(eventId: currentEvent.id)) ?? []
        participants = (try? await env.events.participants(eventId: currentEvent.id)) ?? []
        if let userId = session.user?.id {
            photosOfMe = ((try? await env.matches.myPhotos(eventId: currentEvent.id, userId: userId)) ?? []).count
        }
        sharedMatches = (try? await env.matches.sharedAlbum(eventId: currentEvent.id)) ?? []
        sharedCount = sharedMatches.count
    }

    private func syncRosterIdentities() async throws {
        let functions = Functions.functions()
        let _: Any = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Any, Error>) in
            functions.httpsCallable("syncEventRosterIdentities").call(["eventId": currentEvent.id]) { result, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: result?.data as Any)
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Theme.sunset, Theme.pink, Theme.violet], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.11)).frame(width: 180, height: 180).offset(x: 200, y: -70)
            Image(systemName: currentEvent.category.systemImage)
                .font(.system(size: 92, weight: .semibold))
                .foregroundStyle(.white.opacity(0.13))
                .offset(x: 230, y: -30)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.18))
                        Image(systemName: currentEvent.category.systemImage).font(.title2).foregroundStyle(.white)
                    }
                    .frame(width: 52, height: 52)
                    Spacer()
                    lifecyclePill
                }
                Spacer()
                Text(currentEvent.name)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Label(DateFormatting.range(currentEvent.startsAt, currentEvent.endsAt), systemImage: "calendar")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.92))
                    if let role = currentUserRole {
                        Label(role.displayName.uppercased(), systemImage: role == .organizer ? "crown.fill" : role == .admin ? "shield.fill" : "person.fill")
                            .font(.caption2.bold())
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.white.opacity(0.18), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(20)
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Theme.sunset.opacity(0.18), radius: 18, y: 10)
        .padding(.horizontal)
    }

    private var lifecyclePill: some View {
        Text(statusText)
            .font(.caption2.bold())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.22), in: Capsule())
            .foregroundStyle(.white)
    }

    private var statusText: String {
        switch currentEvent.status {
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

    private var deletedNotice: some View {
        PremiumCard {
            Label("This event is in Deleted. Restore it to make it active again.", systemImage: "trash.fill")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var syncStatusRow: some View {
        PremiumCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.aqua.opacity(0.14))
                    Image(systemName: "checkmark.icloud.fill").foregroundStyle(Theme.aqua)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Event Sync").font(.headline).foregroundStyle(Theme.ink)
                    Text("Scan this event's date window for new matches").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(EventLifecycle.canSync(currentEvent, clock: env.clock, config: env.config.current) ? "Available" : "Paused")
                    .font(.caption.bold())
                    .foregroundStyle(EventLifecycle.canSync(currentEvent, clock: env.clock, config: env.config.current) ? .green : .secondary)
            }
        }
        .padding(.horizontal)
    }

    private var featureGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            NavigationLink { MyPhotosView(event: currentEvent) } label: {
                GradientTile(title: "My Photos", subtitle: "\(photosOfMe) found of you", systemImage: "person.crop.rectangle.stack.fill", gradient: Theme.brandGradient)
            }
            NavigationLink { SharedAlbumView(event: currentEvent) } label: {
                GradientTile(title: "Shared Album", subtitle: "\(sharedCount) shared previews", systemImage: "person.2.crop.square.stack.fill", gradient: Theme.socialGradient)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var statsRow: some View {
        PremiumCard {
            HStack(spacing: 0) {
                statTile(value: "\(sharedCount)", label: "Shared", icon: "photo.stack.fill", tint: Theme.sunset)
                Divider().frame(height: 46)
                statTile(value: "\(photosOfMe)", label: "Of You", icon: "person.fill", tint: Theme.violet)
                Divider().frame(height: 46)
                NavigationLink { SyncView(event: currentEvent) } label: {
                    statTile(value: "Sync", label: "Camera", icon: "arrow.triangle.2.circlepath", tint: Theme.aqua)
                }
                .buttonStyle(.plain)
                .disabled(!EventLifecycle.canSync(currentEvent, clock: env.clock, config: env.config.current))
            }
        }
        .padding(.horizontal)
    }

    private func statTile(value: String, label: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).font(.headline).foregroundStyle(Theme.ink)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var membersRow: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Event Members", systemImage: "person.3.fill").font(.headline).foregroundStyle(Theme.ink)
                    Spacer()
                    NavigationLink("View all") { ParticipantsView(event: currentEvent) }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.sunset)
                }
                HStack(spacing: -8) {
                    ForEach(members.prefix(6)) { member in memberAvatar(member) }
                    if members.count > 6 {
                        ZStack {
                            Circle().fill(Theme.peach.opacity(0.55))
                            Text("+\(members.count - 6)").font(.caption2.bold()).foregroundStyle(Theme.ink)
                        }
                        .frame(width: 42, height: 42)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func memberAvatar(_ member: EventMember) -> some View {
        ZStack {
            Circle().fill(member.role == .organizer ? Theme.brandGradient : member.role == .admin ? Theme.violetGradient : Theme.socialGradient)
            Text(initial(for: member)).font(.caption.bold()).foregroundStyle(.white)
        }
        .frame(width: 42, height: 42)
        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        .accessibilityLabel(member.role.displayName)
    }

    private var invitePeopleRow: some View {
        NavigationLink { ShareEventView(event: currentEvent) } label: {
            PremiumCard {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Theme.sunset.opacity(0.12))
                        Image(systemName: "person.badge.plus").font(.title3).foregroundStyle(Theme.sunset)
                    }
                    .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invite People").font(.headline).foregroundStyle(Theme.ink)
                        Text("Share code, link, QR or phone invite").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private func initial(for member: EventMember) -> String {
        if member.userId == session.user?.id {
            if let name = session.user?.displayName, let first = name.first { return String(first).uppercased() }
            if let phone = session.user?.phoneNumber { return String(phone.suffix(2)) }
        }
        if let participant = participants.first(where: { $0.userId == member.userId }) {
            if let name = participant.displayName, let first = name.first { return String(first).uppercased() }
            if let phone = participant.phoneNumber { return String(phone.suffix(2)) }
        }
        return "?"
    }

    private var organizerControls: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Organizer Controls", systemImage: "crown.fill")
                    .font(.subheadline.bold()).foregroundStyle(Theme.ink)

                if currentEvent.status != .deletedByOrganizer {
                    NavigationLink {
                        EditEventView(event: currentEvent) { updated in
                            currentEvent = updated
                            session.activeEvent = updated
                            Task { await loadDashboard() }
                        }
                    } label: {
                        Label("Edit Event", systemImage: "pencil.circle.fill")
                    }
                }

                if currentEvent.status == .endedByOrganizer {
                    Button {
                        Task { await changeStatus { try await env.events.reopenEvent(id: currentEvent.id) } }
                    } label: { Label("Reopen Event", systemImage: "arrow.counterclockwise.circle.fill") }
                    .disabled(isChangingStatus)
                }

                if currentEvent.status == .deletedByOrganizer {
                    Button {
                        Task { await changeStatus { try await env.events.restoreEvent(id: currentEvent.id) } }
                    } label: { Label("Restore Event", systemImage: "arrow.uturn.backward.circle.fill") }
                    .disabled(isChangingStatus)
                } else {
                    if currentEvent.status == .active {
                        Button(role: .destructive) { confirmEnd = true } label: { Label("End Event", systemImage: "stop.circle.fill") }
                            .disabled(isChangingStatus)
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Move to Deleted", systemImage: "trash.fill") }
                        .disabled(isChangingStatus)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
