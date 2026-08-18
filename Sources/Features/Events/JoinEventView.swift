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
            case .joinEventByToken(let token): event = try await env.events.fetchEvent(inviteToken: token)
            case .joinEventByCode(let code): event = try await env.events.fetchEvent(joinCode: code)
            }

            switch event.status {
            case .active: break
            case .endedByOrganizer: phase = .error("The organizer ended this event."); return
            case .deletedByOrganizer: phase = .error("This event is no longer accepting joins."); return
            case .expired: phase = .error("This event has expired."); return
            }

            participantCount = (try? await env.events.members(eventId: event.id).count) ?? 0
            phase = session?.hasFaceProfile == true ? .ready(event) : .needsFaceSetup(event)
        } catch let error as AppError { phase = .error(error.userMessage) }
        catch { phase = .error(AppError.unknown("\(error)").userMessage) }
    }

    func join(event: Event) async {
        guard let env, let user = session?.user, let profile = session?.faceProfile else { return }
        isJoining = true
        defer { isJoining = false }
        do {
            let svc = EventMembershipService(repository: env.events, config: env.config, clock: env.clock)
            try await svc.join(event: event, user: user, faceProfile: profile)
            phase = .joined
        } catch let error as AppError { phase = .error(error.userMessage) }
        catch { phase = .error(AppError.unknown("\(error)").userMessage) }
    }

    func decline(event: Event) async {
        isDeclining = true
        defer { isDeclining = false }
        do {
            try await EventInviteClient.decline(eventId: event.id)
            phase = .declined
        } catch { phase = .error((error as NSError).localizedDescription) }
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
        ZStack {
            BrandScreenBackground()
            Group {
                switch model.phase {
                case .loading:
                    VStack(spacing: 16) {
                        BrandMark(size: 62)
                        ProgressView()
                        Text("Opening invitation…").font(.subheadline).foregroundStyle(.secondary)
                    }
                case .ready(let event): joinCard(event, needsFaceSetup: false)
                case .needsFaceSetup(let event): joinCard(event, needsFaceSetup: true)
                case .error(let message):
                    PremiumCard {
                        VStack(spacing: 14) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 38)).foregroundStyle(Theme.sunset)
                            Text("Couldn't open this invite").font(.title3.bold())
                            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(24)
                case .joined:
                    VStack(spacing: 12) { ProgressView(); Text("Joining event…").foregroundStyle(.secondary) }
                case .declined:
                    PremiumCard {
                        VStack(spacing: 12) {
                            Image(systemName: "hand.raised.fill").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text("Invitation declined").font(.title3.bold())
                            Text("You have not joined this event.").foregroundStyle(.secondary)
                            Button("Done") { dismiss() }.buttonStyle(MyPicsTubePrimaryButtonStyle())
                        }
                    }
                    .padding(24)
                }
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
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.sky.opacity(0.14))
                    Image(systemName: event.category.systemImage)
                        .font(.system(size: 38)).foregroundStyle(Theme.violet)
                }
                .frame(width: 86, height: 86)

                Text(event.name)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text(event.category.displayName.uppercased())
                    .font(.caption.bold()).foregroundStyle(Theme.sunset)
                Label(DateFormatting.range(event.startsAt, event.endsAt), systemImage: "calendar")
                    .font(.subheadline).foregroundStyle(.secondary)
                if model.participantCount > 0 {
                    Label("\(model.participantCount) already joined", systemImage: "person.2.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                consentBox

                if needsFaceSetup {
                    NavigationLink {
                        FaceSetupView(onSaved: { Task { await model.load(route: route) } })
                    } label: {
                        Label("Set Up My Face", systemImage: "faceid")
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())

                    Text("Face Setup is required for the current MVP matching flow. After saving it, you'll return here to join.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    Button {
                        Task {
                            await model.join(event: event)
                            if case .joined = model.phase { onJoined(event) }
                        }
                    } label: {
                        HStack {
                            if model.isJoining { ProgressView().tint(.white) }
                            else { Image(systemName: "checkmark.circle.fill") }
                            Text("Accept & Join Event")
                        }
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())
                    .disabled(model.isJoining || model.isDeclining)
                }

                if isPhoneInvitation {
                    Button("Decline Invitation", role: .destructive) {
                        Task { await model.decline(event: event) }
                    }
                    .disabled(model.isJoining || model.isDeclining)
                }
            }
            .padding(22)
        }
    }

    private var consentBox: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("How MyPicsTube works here", systemImage: "sparkles")
                    .font(.subheadline.bold()).foregroundStyle(Theme.ink)
                Text("Participating members scan their own photo libraries on-device for this event. You can leave the event or remove Face Setup later.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
