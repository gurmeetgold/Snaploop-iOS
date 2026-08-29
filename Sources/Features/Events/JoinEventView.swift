import SwiftUI

@MainActor
final class JoinEventModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready(Event)
        case needsFaceSetup(Event)
        case error(String)
        case joined(Event)
        case declined
    }

    @Published var phase: Phase = .loading
    @Published var participantCount = 0
    @Published var inviterLabel: String?
    @Published var isJoining = false
    @Published var isDeclining = false
    @Published var actionError: String?

    private var env: AppEnvironment?
    private var session: AppSession?

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    func load(route: DeepLinkRoute) async {
        guard let env, let session else { return }
        phase = .loading
        actionError = nil
        inviterLabel = nil
        do {
            let event: Event
            switch route {
            case .joinEventByToken(let token):
                event = try await env.events.fetchEvent(inviteToken: token)
            case .joinEventByCode(let code):
                event = try await env.events.fetchEvent(joinCode: code)
            }

            // This server-curated preview can identify the actual Admin who sent
            // a direct phone/in-app invite. For a generic shared link it safely
            // falls back to the Event organizer.
            if AppEnvironment.useLiveServices,
               let preview = try? await EventInviteClient.preview(route: route) {
                inviterLabel = preview.inviterName
            }

            switch event.status {
            case .active: break
            case .endedByOrganizer:
                phase = .error("This Event has ended."); return
            case .deletedByOrganizer:
                phase = .error("This Event is no longer available."); return
            case .expired:
                phase = .error("This Event has expired."); return
            }

            if let roster = try? await env.events.members(eventId: event.id) {
                participantCount = roster.count
                if inviterLabel == nil,
                   let organizer = roster.first(where: { $0.userId == event.creatorUserId }),
                   let name = organizer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    inviterLabel = name
                }
                if let userId = session.user?.id,
                   roster.contains(where: { $0.userId == userId }) {
                    phase = .joined(event)
                    return
                }
            } else {
                participantCount = 0
            }

            phase = session.hasFaceProfile ? .ready(event) : .needsFaceSetup(event)
        } catch let error as AppError {
            phase = .error(error.userMessage)
        } catch {
            phase = .error(AppError.unknown("\(error)").userMessage)
        }
    }

    func join(event: Event) async {
        guard !isJoining, !isDeclining else { return }
        guard let env, let user = session?.user, let profile = session?.faceProfile else { return }
        isJoining = true
        actionError = nil
        defer { isJoining = false }
        do {
            let service = EventMembershipService(repository: env.events, config: env.config, clock: env.clock)
            try await service.join(event: event, user: user, faceProfile: profile)
            phase = .joined(event)
        } catch let error as AppError {
            actionError = error.userMessage
        } catch {
            actionError = AppError.unknown("\(error)").userMessage
        }
    }

    func decline(event: Event) async {
        guard !isJoining, !isDeclining else { return }
        isDeclining = true
        actionError = nil
        defer { isDeclining = false }
        do {
            try await EventInviteClient.decline(eventId: event.id)
            phase = .declined
        } catch {
            actionError = (error as NSError).localizedDescription
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
        ZStack {
            BrandScreenBackground()
            Group {
                switch model.phase {
                case .loading:
                    VStack(spacing: 14) {
                        BrandMark(size: 58)
                        ProgressView()
                        Text("Opening invitation…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .ready(let event):
                    joinCard(event, needsFaceSetup: false)
                case .needsFaceSetup(let event):
                    joinCard(event, needsFaceSetup: true)
                case .error(let message):
                    PremiumCard {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(Theme.sunset)
                            Text("Couldn't open this invite")
                                .font(.title3.bold())
                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(24)
                case .joined:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Opening Event…").foregroundStyle(.secondary)
                    }
                case .declined:
                    PremiumCard {
                        VStack(spacing: 12) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.secondary)
                            Text("Invitation declined").font(.title3.bold())
                            Button("Done") { dismiss() }
                                .buttonStyle(MyPicsTubePrimaryButtonStyle())
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Invitation")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.configure(env: env, session: session)
            await model.load(route: route)
            openIfJoined()
        }
        .onChange(of: model.phase) { _, _ in openIfJoined() }
    }

    private func openIfJoined() {
        if case .joined(let event) = model.phase {
            onJoined(event)
            dismiss()
        }
    }

    @ViewBuilder
    private func joinCard(_ event: Event, needsFaceSetup: Bool) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 4)

                ZStack {
                    Circle().fill(Theme.sky.opacity(0.14))
                    Image(systemName: event.category.systemImage)
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.violet)
                }
                .frame(width: 76, height: 76)

                VStack(spacing: 6) {
                    Text("You're invited to")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(event.name)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    if let inviter = model.inviterLabel {
                        Label("Invited by \(inviter)", systemImage: "person.crop.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.violet)
                    }
                }

                PremiumCard {
                    VStack(spacing: 10) {
                        Label(DateFormatting.range(event.startsAt, event.endsAt), systemImage: "calendar")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)

                        Text("SnapLoop scans only photos taken during these Event dates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if model.participantCount > 0 {
                            Label("\(model.participantCount) members", systemImage: "person.2.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        Label("Face matching happens on participating iPhones", systemImage: "iphone")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }

                Text("Join this Event to get photos of you found on participating members’ phones.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                if needsFaceSetup {
                    NavigationLink {
                        FaceSetupView(onSaved: { Task { await model.load(route: route) } })
                    } label: {
                        Label("Set Up My Face", systemImage: "faceid")
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())

                    Text("Face Setup is needed before you can join and receive matched photos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Button {
                        guard !model.isJoining, !model.isDeclining else { return }
                        Task { await model.join(event: event) }
                    } label: {
                        HStack {
                            if model.isJoining { ProgressView().tint(.white) }
                            else { Image(systemName: "checkmark.circle.fill") }
                            Text(model.isJoining ? "Joining…" : "Join Event")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())
                    .disabled(model.isJoining || model.isDeclining)
                }

                if let actionError = model.actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                if isPhoneInvitation {
                    Button(role: .destructive) {
                        guard !model.isJoining, !model.isDeclining else { return }
                        Task { await model.decline(event: event) }
                    } label: {
                        HStack(spacing: 7) {
                            if model.isDeclining { ProgressView() }
                            Text(model.isDeclining ? "Declining…" : "Decline")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(model.isJoining || model.isDeclining)
                }
            }
            .padding(22)
        }
    }
}
