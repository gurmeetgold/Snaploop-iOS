import SwiftUI

@MainActor
final class ParticipantsModel: ObservableObject {
    @Published var members: [EventMember] = []
    @Published var sharingEnabled = true
    private var env: AppEnvironment?
    private var session: AppSession?
    let event: Event
    init(event: Event) { self.event = event }
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    private var service: EventMembershipService? {
        guard let env else { return nil }
        return EventMembershipService(repository: env.events, config: env.config, clock: env.clock)
    }

    func reload() async {
        guard let env else { return }
        members = (try? await env.events.members(eventId: event.id)) ?? []
        if let me = members.first(where: { $0.userId == session?.user?.id }) {
            sharingEnabled = me.sharingEnabled
        }
    }

    func setSharing(_ enabled: Bool) async {
        guard let userId = session?.user?.id else { return }
        try? await service?.setSharing(eventId: event.id, userId: userId, enabled: enabled)
        sharingEnabled = enabled
    }

    func leave() async {
        guard let userId = session?.user?.id else { return }
        try? await service?.leave(eventId: event.id, userId: userId)
    }
}

struct ParticipantsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: ParticipantsModel
    @Environment(\.dismiss) private var dismiss
    init(event: Event) { _model = StateObject(wrappedValue: ParticipantsModel(event: event)) }

    var body: some View {
        List {
            Section("Your sharing") {
                Toggle("Share my photos to this event", isOn: Binding(
                    get: { model.sharingEnabled },
                    set: { newValue in Task { await model.setSharing(newValue) } }))
                Button(role: .destructive) {
                    Task { await model.leave(); dismiss() }
                } label: { Label("Leave Event", systemImage: "rectangle.portrait.and.arrow.right") }
            }
            Section("Participants") {
                ForEach(model.members) { member in
                    HStack {
                        Image(systemName: "person.crop.circle.fill").foregroundStyle(.tint)
                        Text(member.userId)   // resolved to display name in Firebase layer
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
        .task { model.configure(env: env, session: session); await model.reload() }
    }
}
