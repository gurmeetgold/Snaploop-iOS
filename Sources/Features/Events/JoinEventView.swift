import SwiftUI

@MainActor
final class JoinEventModel: ObservableObject {
    enum Phase: Equatable { case loading, ready(Event), needsFaceSetup(Event), error(String), joined }
    @Published var phase: Phase = .loading
    @Published var participantCount = 0
    @Published var isJoining = false

    private var env: AppEnvironment?
    private var session: AppSession?
    init() {}
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    /// Resolve the route to an event and show the Join screen.
    func load(route: DeepLinkRoute) async {
        guard let env else { return }
        phase = .loading
        do {
            let event: Event
            switch route {
            case .joinEventByToken(let token):
                event = try await env.events.fetchEvent(inviteToken: token)
            case .joinEventByCode(let code):
                event = try await env.events.fetchEvent(joinCode: code)
            }
            participantCount = (try? await env.events.members(eventId: event.id).count) ?? 0
            // Route through face setup first if needed (Phase 1 dependency).
            if session?.hasFaceProfile == true {
                phase = .ready(event)
            } else {
                phase = .needsFaceSetup(event)
            }
        } catch let error as AppError {
            phase = .error(error.userMessage)
        } catch {
            phase = .error(AppError.unknown("\(error)").userMessage)
        }
    }

    func join(event: Event) async {
        guard let env, let user = session?.user, let profile = session?.faceProfile else { return }
        isJoining = true; defer { isJoining = false }
        do {
            let svc = EventMembershipService(repository: env.events, config: env.config, clock: env.clock)
            try await svc.join(event: event, user: user, faceProfile: profile)
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
            case .ready(let event), .needsFaceSetup(let event):
                joinCard(event)
            case .error(let message):
                ContentUnavailableViewCompat(title: "Couldn't open this invite", message: message)
            case .joined:
                ProgressView()
            }
        }
        .task {
            model.configure(env: env, session: session)
            await model.load(route: route)
        }
    }

    private func joinCard(_ event: Event) -> some View {
        VStack(spacing: 20) {
            Image(systemName: event.category.systemImage)
                .font(.system(size: 44)).foregroundStyle(.tint)
            Text(event.name).font(.title2).bold().multilineTextAlignment(.center)
            Text(DateFormatting.range(event.startsAt, event.endsAt))
                .font(.subheadline).foregroundStyle(.secondary)
            Label("\(model.participantCount) already joined", systemImage: "person.2.fill")
                .font(.footnote).foregroundStyle(.secondary)

            consentBox

            Button {
                Task {
                    await model.join(event: event)
                    if case .joined = model.phase { onJoined(event) }
                }
            } label: {
                Text(session.hasFaceProfile ? "Join Event" : "Set up your face & join")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isJoining)
        }
        .padding()
    }

    private var consentBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("How SnapLoop works here", systemImage: "sparkles")
                .font(.subheadline).bold()
            Text("While this event is on, SnapLoop finds photos that include people who joined, and makes those photos available to them. Joining is your okay for this — there's no photo-by-photo step. You can pause sharing or leave anytime.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
