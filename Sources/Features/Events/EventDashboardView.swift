import SwiftUI

struct EventDashboardView: View {
    let event: Event
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @State private var members: [EventMember] = []
    @State private var photosOfMe = 0
    @State private var sharedCount = 0

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
                syncStatusRow
                featureGrid
                statsRow
                membersRow
                if isOrganizer { organizerControls }
            }
            .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(edges: .top)
        .task {
            session.activeEvent = event
            members = (try? await env.events.members(eventId: event.id)) ?? []
            if let userId = session.user?.id {
                photosOfMe = ((try? await env.matches.myPhotos(eventId: event.id, userId: userId)) ?? []).count
            }
            sharedCount = ((try? await env.matches.sharedAlbum(eventId: event.id)) ?? []).count
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
                }
            }
            .padding(20)
        }
        .frame(height: 220)
    }

    private var lifecyclePill: some View {
        let text: String
        switch lifecycle {
        case .upcoming: text = "UPCOMING"
        case .active: text = "LIVE"
        case .grace: text = "WRAPPING UP"
        case .expired: text = "COMPLETED"
        }
        return Text(text).font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.25), in: Capsule())
            .foregroundStyle(.white)
    }

    private var syncStatusRow: some View {
        HStack {
            Label("Trip Sync", systemImage: "checkmark.icloud.fill")
                .font(.subheadline).bold()
            Spacer()
            Text("Up to date").font(.subheadline).foregroundStyle(.green)
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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
                GradientTile(title: "Shared Album", subtitle: "\(sharedCount) everyone's photos",
                            systemImage: "person.2.fill", gradient: Theme.skyGradient)
            }
            NavigationLink { RequestsView(event: event) } label: {
                GradientTile(title: "Requests", subtitle: "Photos you're waiting for",
                            systemImage: "bell.fill", gradient: Theme.violetGradient)
            }
            NavigationLink { HighlightsView(event: event) } label: {
                GradientTile(title: "AI Highlights", subtitle: "Smart picks from your trip",
                            systemImage: "sparkles", gradient: Theme.amberGradient)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statTile(value: "\(sharedCount)", label: "Total Photos", icon: "photo.stack", tint: .green)
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
                Text("Trip Members").font(.headline)
                Spacer()
                NavigationLink("View all") { ParticipantsView(event: event) }
                    .font(.subheadline)
            }
            HStack(spacing: -8) {
                ForEach(members.prefix(6)) { member in
                    ZStack {
                        Circle().fill(Theme.violetGradient)
                        Text(String(member.userId.prefix(1)).uppercased())
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

    private var organizerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Organizer").font(.subheadline).bold().foregroundStyle(.secondary)
            NavigationLink { ShareEventView(event: event) } label: {
                Label("Invite People / QR Code", systemImage: "person.badge.plus")
            }
            NavigationLink { Text("Edit flow (Phase 2 create form reused)") } label: {
                Label("Edit Trip", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { try? await env.events.endEvent(id: event.id) }
            } label: {
                Label("End Trip", systemImage: "stop.circle")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator.opacity(0.4)))
        .padding(.horizontal)
    }
}
