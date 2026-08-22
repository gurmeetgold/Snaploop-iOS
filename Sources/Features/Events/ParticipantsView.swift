import SwiftUI

@MainActor
final class ParticipantsModel: ObservableObject {
    @Published var members: [EventMember] = []
    @Published var sharingEnabled = true
    @Published var errorMessage: String?

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
        do {
            members = try await env.events.members(eventId: event.id)
            if let me = members.first(where: { $0.userId == session?.user?.id }) {
                sharingEnabled = me.sharingEnabled
            }
            errorMessage = nil
        } catch {
            members = []
            errorMessage = EventManagementClient.userMessage(for: error)
        }
    }

    func displayName(for member: EventMember) -> String {
        if member.userId == session?.user?.id {
            if let name = session?.user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return "\(name) (You)"
            }
        }
        if let name = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "Event member"
    }

    func initial(for member: EventMember) -> String {
        let name = displayName(for: member).replacingOccurrences(of: " (You)", with: "")
        return String(name.prefix(1)).uppercased()
    }

    var currentUserRole: EventMember.Role? {
        guard let userId = session?.user?.id else { return nil }
        if event.creatorUserId == userId { return .organizer }
        return members.first(where: { $0.userId == userId })?.role
    }

    var currentUserCanInvite: Bool { currentUserRole?.canManageMembers == true }
    var currentUserIsOrganizer: Bool { currentUserRole == .organizer }

    func canManage(_ member: EventMember) -> Bool {
        guard member.userId != session?.user?.id, member.role != .organizer else { return false }
        switch currentUserRole {
        case .organizer: return true
        case .admin: return member.role == .participant
        default: return false
        }
    }

    func setSharing(_ enabled: Bool) async {
        guard let userId = session?.user?.id else { return }
        errorMessage = nil
        do {
            try await service?.setSharing(eventId: event.id, userId: userId, enabled: enabled)
            sharingEnabled = enabled
            await reload()
        } catch {
            errorMessage = EventManagementClient.userMessage(for: error)
        }
    }

    func leave() async {
        guard currentUserRole != .organizer, let userId = session?.user?.id else { return }
        errorMessage = nil
        do {
            try await service?.leave(eventId: event.id, userId: userId)
        } catch {
            errorMessage = EventManagementClient.userMessage(for: error)
        }
    }

    func remove(_ member: EventMember) async {
        errorMessage = nil
        do {
            if AppEnvironment.useLiveServices {
                try await EventManagementClient.remove(eventId: event.id, userId: member.userId)
            } else {
                try await env?.events.removeMember(eventId: event.id, userId: member.userId)
            }
            await reload()
            errorMessage = nil
        } catch {
            errorMessage = EventManagementClient.userMessage(for: error)
        }
    }

    func setRole(_ role: EventMember.Role, for member: EventMember) async {
        guard currentUserIsOrganizer else { return }
        errorMessage = nil
        do {
            if AppEnvironment.useLiveServices {
                try await EventManagementClient.setRole(eventId: event.id, userId: member.userId, role: role)
            } else if let index = members.firstIndex(where: { $0.userId == member.userId }) {
                members[index].role = role
            }
            await reload()
            errorMessage = nil
        } catch {
            errorMessage = EventManagementClient.userMessage(for: error)
        }
    }
}

struct ParticipantsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: ParticipantsModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLeave = false

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
                            Toggle("Show matched pictures from my phone in this Event", isOn: Binding(
                                get: { model.sharingEnabled },
                                set: { value in Task { await model.setSharing(value) } }
                            ))
                            .tint(Theme.sunset)

                            Text("When this is on, SnapLoop can share matched Event previews found on your phone with the people they match.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if model.currentUserCanInvite {
                                NavigationLink { ShareEventView(event: model.event) } label: {
                                    Label("Invite People", systemImage: "person.badge.plus")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(Theme.sunset)
                                }
                            }

                            if model.currentUserRole != .organizer {
                                Button(role: .destructive) { confirmLeave = true } label: {
                                    Label("Leave Event", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            } else {
                                Label("Organizer controls for editing, ending and deleting are on the Event screen.", systemImage: "crown.fill")
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
                                        Text(model.displayName(for: member))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.ink)
                                        Text(member.role.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    roleBadge(member.role)
                                    if model.canManage(member) {
                                        managementMenu(member)
                                    }
                                }
                                .padding(.vertical, 10)
                                if member.id != model.members.last?.id {
                                    Divider().padding(.leading, 56)
                                }
                            }
                        }
                    }

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.configure(env: env, session: session)
            await model.reload()
        }
        .refreshable { await model.reload() }
        .confirmationDialog("Leave this Event?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave Event", role: .destructive) {
                Task {
                    await model.leave()
                    if model.errorMessage == nil {
                        session.activeEvent = nil
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your membership will be removed from this Event.")
        }
    }

    private func memberAvatar(_ member: EventMember) -> some View {
        ZStack {
            Circle().fill(member.role == .organizer ? Theme.brandGradient : member.role == .admin ? Theme.violetGradient : Theme.socialGradient)
            Text(model.initial(for: member)).font(.subheadline.bold()).foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func roleBadge(_ role: EventMember.Role) -> some View {
        if role == .organizer {
            Label("Organizer", systemImage: "crown.fill")
                .font(.caption2.bold()).foregroundStyle(Theme.sunset)
        } else if role == .admin {
            Label("Admin", systemImage: "shield.fill")
                .font(.caption2.bold()).foregroundStyle(Theme.violet)
        }
    }

    private func managementMenu(_ member: EventMember) -> some View {
        Menu {
            if model.currentUserIsOrganizer {
                if member.role == .participant {
                    Button { Task { await model.setRole(.admin, for: member) } } label: {
                        Label("Make Admin", systemImage: "shield.fill")
                    }
                } else if member.role == .admin {
                    Button { Task { await model.setRole(.participant, for: member) } } label: {
                        Label("Change to Member", systemImage: "person.fill")
                    }
                }
            }
            Button(role: .destructive) { Task { await model.remove(member) } } label: {
                Label("Remove from Event", systemImage: "person.crop.circle.badge.minus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Manage \(model.displayName(for: member))")
    }
}
