import FirebaseFunctions
import SwiftUI

struct EventDashboardView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var currentEvent: Event
    @State private var members: [EventMember] = []
    @State private var photosOfMe = 0
    @State private var confirmEnd = false
    @State private var confirmDelete = false
    @State private var actionError: String?
    @State private var isChangingStatus = false
    @State private var syncDisplayState: SyncDisplayState = .checking

    private enum SyncDisplayState {
        case checking
        case automatic
        case sharingOff
        case needsPhotoAccess
        case paused

        var title: String {
            switch self {
            case .checking: return "Checking"
            case .automatic: return "Automatic"
            case .sharingOff: return "Sharing off"
            case .needsPhotoAccess: return "Needs access"
            case .paused: return "Paused"
            }
        }

        var detail: String {
            switch self {
            case .checking: return "Checking this Event's photo status"
            case .automatic: return "SnapLoop automatically checks this Event for new photos"
            case .sharingOff: return "Photo sharing is turned off for this Event"
            case .needsPhotoAccess: return "Allow Photos access to check this Event"
            case .paused: return "Photo scanning is paused for this Event"
            }
        }

        var systemImage: String {
            switch self {
            case .checking: return "clock"
            case .automatic: return "cloud.fill"
            case .sharingOff: return "pause.circle.fill"
            case .needsPhotoAccess: return "exclamationmark.triangle.fill"
            case .paused: return "pause.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .checking, .paused: return .secondary
            case .automatic: return Theme.aqua
            case .sharingOff: return .orange
            case .needsPhotoAccess: return .red
            }
        }
    }

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
    private var canManageEvent: Bool { currentUserRole == .organizer || currentUserRole == .admin }
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
                        if isOrganizer { managerControls }
                    } else {
                        syncStatusRow
                        featureGrid
                        membersRow
                        if currentEvent.status == .active && canManageMembers { invitePeopleRow }
                        if canManageEvent { managerControls }
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
        .confirmationDialog("End this Event?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End Event", role: .destructive) {
                Task { await changeStatus { try await env.events.endEvent(id: currentEvent.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("New joins and photo scans will stop.") }
        .confirmationDialog("Move this Event to Deleted?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move to Deleted", role: .destructive) {
                Task { await changeStatus { try await env.events.moveEventToDeleted(id: currentEvent.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The Event will move to Deleted and can be restored while it is still retained.") }
    }

    @MainActor
    private func loadDashboard() async {
        session.activeEvent = currentEvent
        members = (try? await env.events.members(eventId: currentEvent.id)) ?? []

        if let userId = session.user?.id {
            let matches = (try? await env.matches.myPhotos(eventId: currentEvent.id, userId: userId)) ?? []
            let sharingEnabled = members.first(where: { $0.userId == userId })?.sharingEnabled ?? false
            photosOfMe = matches.filter { sharingEnabled || $0.ownerUserId != userId }.count
        }

        refreshSyncDisplayState()
    }

    @MainActor
    private func refreshSyncDisplayState() {
        guard EventLifecycle.canSync(currentEvent, clock: env.clock, config: env.config.current) else {
            syncDisplayState = .paused
            return
        }
        guard env.photoLibrary.authorizationStatus().canRead else {
            syncDisplayState = .needsPhotoAccess
            return
        }
        guard let userId = session.user?.id else {
            syncDisplayState = .paused
            return
        }
        let sharingEnabled = members.first(where: { $0.userId == userId })?.sharingEnabled ?? false
        syncDisplayState = sharingEnabled ? .automatic : .sharingOff
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
                        RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.18))
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    if let role = currentUserRole {
                        Label(
                            role.displayName.uppercased(),
                            systemImage: role == .organizer ? "crown.fill" : role == .admin ? "shield.fill" : "person.fill"
                        )
                        .font(.caption2.bold())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.18), in: Capsule())
                        .foregroundStyle(.white)
                    }
                }
            }
            .padding(20)
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 30))
        .shadow(color: Theme.sunset.opacity(0.18), radius: 18, y: 10)
        .padding(.horizontal)
    }

    private var lifecyclePill: some View {
        Text(statusText)
            .font(.caption2.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
            case .grace: return "PHOTO WINDOW"
            case .expired: return "COMPLETED"
            }
        }
    }

    private var deletedNotice: some View {
        PremiumCard {
            Label("This Event is in Deleted.", systemImage: "trash.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var syncStatusRow: some View {
        PremiumCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(syncDisplayState.tint.opacity(0.14))
                    Image(systemName: syncDisplayState.systemImage).foregroundStyle(syncDisplayState.tint)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photo Scan").font(.headline).foregroundStyle(Theme.ink)
                    Text(syncDisplayState.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(syncDisplayState.title)
                    .font(.caption.bold())
                    .foregroundStyle(syncDisplayState.tint)
            }
        }
        .padding(.horizontal)
    }

    private var featureGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            NavigationLink { MyPhotosView(event: currentEvent) } label: {
                GradientTile(
                    title: "My Photos",
                    subtitle: "\(photosOfMe) found of you",
                    systemImage: "person.crop.rectangle.stack.fill",
                    gradient: Theme.brandGradient
                )
            }
            NavigationLink { SyncView(event: currentEvent) } label: {
                GradientTile(
                    title: "Scan Event Photos",
                    subtitle: "Check this iPhone for matches",
                    systemImage: "photo.stack.fill",
                    gradient: Theme.socialGradient
                )
            }
            .disabled(!EventLifecycle.canSync(currentEvent, clock: env.clock, config: env.config.current))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var membersRow: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Event Members", systemImage: "person.3.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    NavigationLink("View all") { ParticipantsView(event: currentEvent) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.sunset)
                }
                HStack(spacing: -8) {
                    ForEach(members.prefix(6)) { member in memberAvatar(member) }
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
        if member.userId == session.user?.id,
           let name = session.user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           let first = name.first {
            return String(first).uppercased()
        }
        if let name = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           let first = name.first {
            return String(first).uppercased()
        }
        return "•"
    }

    private var managerControls: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    currentUserRole == .admin ? "Admin Controls" : "Organizer Controls",
                    systemImage: currentUserRole == .admin ? "shield.fill" : "crown.fill"
                )
                .font(.subheadline.bold())
                .foregroundStyle(Theme.ink)

                if currentEvent.status == .active {
                    NavigationLink {
                        EditEventView(event: currentEvent) { updated in
                            currentEvent = updated
                            session.activeEvent = updated
                            Task { await loadDashboard() }
                        }
                    } label: { Label("Edit Event", systemImage: "pencil.circle.fill") }

                    Button(role: .destructive) { confirmEnd = true } label: {
                        Label("End Event", systemImage: "stop.circle.fill")
                    }
                    .disabled(isChangingStatus)
                }

                if isOrganizer {
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
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Move to Deleted", systemImage: "trash.fill")
                        }
                        .disabled(isChangingStatus)
                    }
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
