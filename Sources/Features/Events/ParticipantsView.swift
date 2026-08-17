import FirebaseFunctions
import SwiftUI

@MainActor
final class ParticipantsModel: ObservableObject {
    @Published var members: [EventMember] = []
    @Published var participants: [EventParticipant] = []
    @Published var sharingEnabled = true

    private var env: AppEnvironment?
    private var session: AppSession?

    let event: Event

    init(event: Event) {
        self.event = event
    }

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    private var service: EventMembershipService? {
        guard let env else { return nil }

        return EventMembershipService(
            repository: env.events,
            config: env.config,
            clock: env.clock
        )
    }

    func reload() async {
        guard let env else { return }

        // Server refreshes display-name/phone snapshots for the whole roster so
        // existing trips created before these fields were added are backfilled.
        if AppEnvironment.useLiveServices {
            try? await syncRosterIdentity()
        }

        async let membersResult = env.events.members(eventId: event.id)
        async let participantsResult = env.events.participants(eventId: event.id)

        members = (try? await membersResult) ?? []
        participants = (try? await participantsResult) ?? []

        if let me = members.first(where: { $0.userId == session?.user?.id }) {
            sharingEnabled = me.sharingEnabled
        }
    }

    private func syncRosterIdentity() async throws {
        let functions = Functions.functions()
        let _: Any = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Any, Error>) in
            functions.httpsCallable("syncEventRosterIdentities").call([
                "eventId": event.id
            ]) { result, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: result?.data as Any)
            }
        }
    }

    func displayName(for member: EventMember) -> String {
        if member.userId == session?.user?.id {
            if let myName = session?.user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !myName.isEmpty {
                return "\(myName) (You)"
            }
            if let phone = session?.user?.phoneNumber, !phone.isEmpty {
                return "\(phone) (You)"
            }
        }

        if let participant = participants.first(where: { $0.userId == member.userId }) {
            if let name = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
            if let phone = participant.phoneNumber, !phone.isEmpty {
                return phone
            }
        }

        return member.role == .organizer ? "Organizer" : "Participant"
    }

    func initial(for member: EventMember) -> String {
        let name = displayName(for: member)
            .replacingOccurrences(of: " (You)", with: "")

        return String(name.prefix(1)).uppercased()
    }

    func setSharing(_ enabled: Bool) async {
        guard let userId = session?.user?.id else { return }

        try? await service?.setSharing(
            eventId: event.id,
            userId: userId,
            enabled: enabled
        )

        sharingEnabled = enabled
    }

    func leave() async {
        guard let userId = session?.user?.id else { return }

        try? await service?.leave(
            eventId: event.id,
            userId: userId
        )
    }
}

struct ParticipantsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: ParticipantsModel
    @Environment(\.dismiss) private var dismiss

    init(event: Event) {
        _model = StateObject(
            wrappedValue: ParticipantsModel(event: event)
        )
    }

    var body: some View {
        List {
            Section("Your sharing") {
                Toggle(
                    "Share my photos to this event",
                    isOn: Binding(
                        get: { model.sharingEnabled },
                        set: { newValue in
                            Task {
                                await model.setSharing(newValue)
                            }
                        }
                    )
                )

                NavigationLink {
                    ShareEventView(event: model.event)
                } label: {
                    Label("Invite People", systemImage: "person.badge.plus")
                }

                Button(role: .destructive) {
                    Task {
                        await model.leave()
                        dismiss()
                    }
                } label: {
                    Label(
                        "Leave Event",
                        systemImage: "rectangle.portrait.and.arrow.right"
                    )
                }
            }

            Section("Participants") {
                ForEach(model.members) { member in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Theme.coralGradient)

                            Text(model.initial(for: member))
                                .font(.subheadline)
                                .bold()
                                .foregroundStyle(.white)
                        }
                        .frame(width: 34, height: 34)

                        Text(model.displayName(for: member))

                        Spacer()

                        if member.role == .organizer {
                            StatusPill(text: "Organizer", tint: .blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Participants")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.configure(env: env, session: session)
            await model.reload()
        }
        .refreshable {
            await model.reload()
        }
    }
}
