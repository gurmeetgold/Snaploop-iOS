import SwiftUI

struct EventDashboardView: View {
    let event: Event
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @State private var members: [EventMember] = []

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
                header
                syncCard
                featureGrid
                if isOrganizer { organizerControls }
            }
            .padding()
        }
        .navigationTitle(event.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { members = (try? await env.events.members(eventId: event.id)) ?? [] }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(event.category.displayName, systemImage: event.category.systemImage)
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                lifecyclePill
            }
            Text(DateFormatting.range(event.startsAt, event.endsAt))
                .font(.subheadline).foregroundStyle(.secondary)
            if let location = event.locationName {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Label("\(members.count) participants", systemImage: "person.2.fill")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var lifecyclePill: some View {
        switch lifecycle {
        case .upcoming: return StatusPill(text: "Starts soon", tint: .blue, systemImage: "clock")
        case .active:   return StatusPill(text: "Live", tint: .green, systemImage: "dot.radiowaves.left.and.right")
        case .grace:    return StatusPill(text: "Wrapping up", tint: .orange, systemImage: "hourglass")
        case .expired:  return StatusPill(text: "Ended", tint: .secondary, systemImage: "checkmark.seal")
        }
    }

    private var syncCard: some View {
        VStack(spacing: 12) {
            Text("Find your photos from this event")
                .font(.subheadline).foregroundStyle(.secondary)
            NavigationLink {
                SyncView(event: event)
            } label: {
                Label("Sync My Camera", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!EventLifecycle.canSync(event, clock: env.clock, config: env.config.current))
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var featureGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            NavigationLink { MyPhotosView(event: event) } label: {
                dashboardTile("My Photos", "photo.stack", "Photos of you")
            }
            NavigationLink { SharedAlbumView(event: event) } label: {
                dashboardTile("Shared Album", "square.grid.2x2", "Everyone's photos")
            }
            NavigationLink { ParticipantsView(event: event) } label: {
                dashboardTile("Participants", "person.3", "\(members.count) joined")
            }
            NavigationLink { HighlightsView(event: event) } label: {
                dashboardTile("Highlights", "sparkles", "Best moments")
            }
        }
        .buttonStyle(.plain)
    }

    private func dashboardTile(_ title: String, _ icon: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            Text(title).font(.headline).foregroundStyle(.primary)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var organizerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Organizer").font(.subheadline).bold().foregroundStyle(.secondary)
            NavigationLink { ShareEventView(event: event) } label: {
                Label("Invite People / QR Code", systemImage: "person.badge.plus")
            }
            NavigationLink { Text("Edit flow (Phase 2 create form reused)") } label: {
                Label("Edit Event", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { try? await env.events.endEvent(id: event.id) }
            } label: {
                Label("End Event", systemImage: "stop.circle")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
