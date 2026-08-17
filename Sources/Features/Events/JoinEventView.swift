import SwiftUI

@MainActor
final class JoinEventModel: ObservableObject {
    enum Phase: Equatable { case loading, ready(Event), needsFaceSetup(Event), error(String), joined }
    @Published var phase: Phase = .loading
    @Published var participantCount = 0
    @Published var isJoining = false

    private var env: AppEnvironment?
    private var session: AppSession?
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    func load(route: DeepLinkRoute) async {
        guard let env else { return }
        phase = .loading
        do {
            let event: Event
            switch route {
            case .joinEventByToken(let token): event = try await env.events.fetchEvent(inviteToken: token)
            case .joinEventByCode(let code): event = try await env.events.fetchEvent(joinCode: code)
            }
            guard event.status == .active else {
                phase = .error(event.status == .archived ? "This event is no longer accepting joins." : "This event has ended.")
                return
            }
            participantCount = (try? await env.events.members(eventId: event.id).count) ?? 0
            phase = session?.hasFaceProfile == true ? .ready(event) : .needsFaceSetup(event)
        } catch let error as AppError {
            phase = .error(error.userMessage)
        } catch {
            phase = .error(AppError.unknown("\(error)").userMessage)
        }
    }

    func join(event: Event) async {
        guard let env, let user = session?.user, let profile = session?.faceProfile else {
            phase = .error("Complete Face Setup before joining this event.")
            return
        }
        isJoining = true
        defer { isJoining = false }
        do {
            let service = EventMembershipService(repository: env.events, config: env.config, clock: env.clock)
            try await service.join(event: event, user: user, faceProfile: profile)
            phase = .joined
        } catch let error as AppError {
            phase = .error(error.userMessage)
        } catch {
            phase = .error(AppError.unknown("\(error)").userMessage)
        }
    }
}

struct JoinEventView: View {
    let route: DeepLinkRoute
    let onJoined: (Event) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = JoinEventModel()

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("Loading event…")
            case .ready(let event):
                joinCard(event, needsFaceSetup: false)
            case .needsFaceSetup(let event):
                joinCard(event, needsFaceSetup: true)
            case .error(let message):
                ContentUnavailableViewCompat(title: "Couldn't open this invite", message: message)
            case .joined:
                ProgressView("Joining…")
            }
        }
        .task {
            model.configure(env: env, session: session)
            await model.load(route: route)
        }
    }

    @ViewBuilder
    private func joinCard(_ event: Event, needsFaceSetup: Bool) -> some View {
        VStack(spacing: 20) {
            Image(systemName: event.category.systemImage).font(.system(size: 44)).foregroundStyle(.tint)
            Text(event.name).font(.title2).bold().multilineTextAlignment(.center)
            Text(DateFormatting.range(event.startsAt, event.endsAt)).font(.subheadline).foregroundStyle(.secondary)
            if model.participantCount > 0 {
                Label("\(model.participantCount) already joined", systemImage: "person.2.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("How Face Match is used", systemImage: "faceid").font(.subheadline).bold()
                Text("SnapLoop uses your face setup to find confident matches in photos synced for this event. You can remove a wrong match with Not Me.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

            if needsFaceSetup {
                NavigationLink {
                    FaceSetupView(onSaved: { Task { await model.load(route: route) } })
                } label: {
                    Text("Set Up Your Face to Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button {
                    Task {
                        await model.join(event: event)
                        if case .joined = model.phase { onJoined(event) }
                    }
                } label: {
                    Group { if model.isJoining { ProgressView() } else { Text("Join Event") } }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isJoining)
            }
        }
        .padding()
    }
}
