import FirebaseFunctions
import SwiftUI
import UIKit

@MainActor
final class ParticipantsModel: ObservableObject {
    @Published var members: [EventMember] = []
    @Published var participants: [EventParticipant] = []
    @Published var sharedMatches: [PhotoMatch] = []
    @Published var sharingEnabled = true

    private var env: AppEnvironment?
    private var session: AppSession?
    let event: Event

    init(event: Event) { self.event = event }

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    private var service: EventMembershipService? {
        guard let env else { return nil }
        return EventMembershipService(repository: env.events, config: env.config, clock: env.clock)
    }

    func reload() async {
        guard let env else { return }
        if AppEnvironment.useLiveServices { try? await syncRosterIdentity() }
        async let membersResult = env.events.members(eventId: event.id)
        async let participantsResult = env.events.participants(eventId: event.id)
        async let sharedResult = env.matches.sharedAlbum(eventId: event.id)
        members = (try? await membersResult) ?? []
        participants = (try? await participantsResult) ?? []
        sharedMatches = (try? await sharedResult) ?? []
        if let me = members.first(where: { $0.userId == session?.user?.id }) { sharingEnabled = me.sharingEnabled }
    }

    private func syncRosterIdentity() async throws {
        let functions = Functions.functions()
        let _: Any = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Any, Error>) in
            functions.httpsCallable("syncEventRosterIdentities").call(["eventId": event.id]) { result, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: result?.data as Any)
            }
        }
    }

    func displayName(for member: EventMember) -> String {
        if member.userId == session?.user?.id {
            if let myName = session?.user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !myName.isEmpty { return "\(myName) (You)" }
            if let phone = session?.user?.phoneNumber, !phone.isEmpty { return "\(phone) (You)" }
        }
        if let participant = participants.first(where: { $0.userId == member.userId }) {
            if let name = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
            if let phone = participant.phoneNumber, !phone.isEmpty { return phone }
        }
        return member.role == .organizer ? "Organizer" : "Participant"
    }

    func initial(for member: EventMember) -> String {
        let name = displayName(for: member).replacingOccurrences(of: " (You)", with: "")
        return String(name.prefix(1)).uppercased()
    }

    func thumbnailPath(for userId: String) -> String? {
        sharedMatches.first {
            $0.thumbnailPath != nil && $0.activeParticipantIds.contains(userId)
        }?.thumbnailPath
    }

    var currentUserIsOrganizer: Bool {
        guard let userId = session?.user?.id else { return false }
        return members.first(where: { $0.userId == userId })?.role == .organizer || event.creatorUserId == userId
    }

    func setSharing(_ enabled: Bool) async {
        guard let userId = session?.user?.id else { return }
        try? await service?.setSharing(eventId: event.id, userId: userId, enabled: enabled)
        sharingEnabled = enabled
    }

    func leave() async {
        guard !currentUserIsOrganizer, let userId = session?.user?.id else { return }
        try? await service?.leave(eventId: event.id, userId: userId)
    }
}

struct ParticipantsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: ParticipantsModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLeave = false
    @State private var localFaceReferenceData: Data?

    init(event: Event) {
        _model = StateObject(wrappedValue: ParticipantsModel(event: event))
    }

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PremiumCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Your sharing", systemImage: "photo.stack.fill")
                                .font(.headline).foregroundStyle(Theme.ink)
                            Toggle("Share my matched previews to this event", isOn: Binding(
                                get: { model.sharingEnabled },
                                set: { value in Task { await model.setSharing(value) } }
                            ))
                            .tint(Theme.sunset)

                            NavigationLink { ShareEventView(event: model.event) } label: {
                                Label("Invite People", systemImage: "person.badge.plus")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Theme.sunset)
                            }

                            if !model.currentUserIsOrganizer {
                                Button(role: .destructive) { confirmLeave = true } label: {
                                    Label("Leave Event", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            } else {
                                Label("As organizer, manage ending or deleting this event from Organizer Controls.", systemImage: "crown.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Text("Event Members")
                        .font(.title3.bold()).foregroundStyle(Theme.ink)

                    PremiumCard {
                        VStack(spacing: 0) {
                            ForEach(model.members) { member in
                                HStack(spacing: 12) {
                                    memberAvatar(member)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.displayName(for: member)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                        Text(member.role == .organizer ? "Event organizer" : "Event member")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if member.role == .organizer {
                                        Label("Organizer", systemImage: "crown.fill")
                                            .font(.caption2.bold()).foregroundStyle(Theme.sunset)
                                    }
                                }
                                .padding(.vertical, 10)
                                if member.id != model.members.last?.id {
                                    Divider().padding(.leading, 56)
                                }
                            }
                        }
                    }

                    Text("For privacy, other members use an already-shared event photo when available. Face-enrollment reference images are not uploaded just to create avatars.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(20)
            }
        }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.configure(env: env, session: session)
            if let userId = session.user?.id {
                localFaceReferenceData = LocalFaceReferenceStore.load(userId: userId)
            }
            await model.reload()
        }
        .refreshable { await model.reload() }
        .confirmationDialog("Leave this event?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave Event", role: .destructive) {
                Task { await model.leave(); session.activeEvent = nil; dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your membership will be removed from this event.")
        }
    }

    @ViewBuilder
    private func memberAvatar(_ member: EventMember) -> some View {
        if member.userId == session.user?.id,
           let data = localFaceReferenceData,
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .clipped()
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        } else if let path = model.thumbnailPath(for: member.userId) {
            ThumbnailCell(path: path)
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        } else {
            ZStack {
                Circle().fill(member.role == .organizer ? Theme.brandGradient : Theme.socialGradient)
                Text(model.initial(for: member)).font(.subheadline.bold()).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
        }
    }
}
