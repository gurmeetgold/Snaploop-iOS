import SwiftUI

@MainActor
final class JoinEventModel: ObservableObject {
    enum Phase: Equatable { case loading, ready(Event), needsFaceSetup(Event), error(String), joined, declined }
    @Published var phase: Phase = .loading
    @Published var participantCount = 0
    @Published var isJoining = false
    @Published var isDeclining = false

    private var env: AppEnvironment?
    private var session: AppSession?
    init() {}
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

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

            switch event.status {
            case .active:
                break
            case .endedByOrganizer:
                phase = .error("The organizer ended this event.")
                return
            case .deletedByOrganizer:
                phase = .error("This event is no longer accepting joins.")
                return
            case .expired:
                phase = .error("This event has expired.")
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
        guard let env, let user = session?.user, let profile = session?.faceProfile else { return }
        isJoining = true
        defer { isJoining = false }
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

    func decline(event: Event) async {
        isDeclining = true
        defer { isDeclining = false }
        do {
            try await EventInviteClient.decline(eventId: event.id)
            phase = .declined
        } catch {
            phase = .error((error as NSError).localizedDescription)
        }
    }
}

struct JoinEventView: View {
    let route: DeepLinkRoute
    let onJoined: (Event) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = JoinEventModel()

    private var isPhoneInvitation: Bool {
        if case .joinEventByToken = route { return true }
        return false
    }

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
                ProgressView()
            case .declined:
                ContentUnavailableViewCompat(title: "Invitation declined", message: "You have not joined this event.")
                    .toolbar { Button("Done") { dismiss() } }
            }
        }
        .navigationTitle("Join Event")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.configure(env: env, session: session)
            await model.load(route: route)
        }
    }

    @ViewBuilder
    private func joinCard(_ event: Event, needsFaceSetup: Bool) -> some View {
        VStack(spacing: 20) {
            Image(systemName: event.category.systemImage)
                .font(.system(size: 44)).foregroundStyle(.tint)
            Text(event.name).font(.title2).bold().multilineTextAlignment(.center)
            Text(event.category.displayName)
                .font(.caption).bold().foregroundStyle(.secondary)
            Text(DateFormatting.range(event.startsAt, event.endsAt))
                .font(.subheadline).foregroundStyle(.secondary)
            if model.participantCount > 0 {
                Label("\(model.participantCount) already joined", systemImage: "person.2.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            consentBox

            if needsFaceSetup {
                NavigationLink {
                    FaceSetupView(onSaved: {
                        Task { await model.load(route: route) }
                    })
                } label: {
                    Label("Set Up My Face", systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Face Setup is required for the current MVP matching flow. After saving it, you'll return here to join.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Button {
                    Task {
                        await model.join(event: event)
                        if case .joined = model.phase { onJoined(event) }
                    }
                } label: {
                    Group { if model.isJoining { ProgressView() } else { Text("Accept & Join Event") } }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.isJoining || model.isDeclining)
            }

            if isPhoneInvitation {
                Button("Decline Invitation", role: .destructive) {
                    Task { await model.decline(event: event) }
                }
                .disabled(model.isJoining || model.isDeclining)
            }
        }
        .padding()
    }

    private var consentBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("How SnapLoop works here", systemImage: "sparkles")
                .font(.subheadline).bold()
            Text("SnapLoop checks participating members' camera libraries on-device for photos from this event. You can leave the event or remove your Face Setup later.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
