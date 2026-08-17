import SwiftUI

@MainActor
final class SharedAlbumModel: ObservableObject {
    @Published var photos: [PhotoMatch] = []
    @Published var participants: [EventParticipant] = []

    private var env: AppEnvironment?
    let event: Event

    init(event: Event) { self.event = event }
    func configure(env: AppEnvironment) { self.env = env }

    func reload() async {
        guard let env else { return }
        async let photosResult = env.matches.sharedAlbum(eventId: event.id)
        async let participantsResult = env.events.participants(eventId: event.id)
        photos = (try? await photosResult) ?? []
        participants = (try? await participantsResult) ?? []
    }

    func ownerLabel(for userId: String) -> String {
        guard let participant = participants.first(where: { $0.userId == userId }) else {
            return "Event member"
        }
        if let name = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let phone = participant.phoneNumber, !phone.isEmpty { return phone }
        return "Event member"
    }

    var contributorCount: Int { Set(photos.map(\.ownerUserId)).count }
}

struct SharedAlbumView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model: SharedAlbumModel

    init(event: Event) {
        _model = StateObject(wrappedValue: SharedAlbumModel(event: event))
    }

    private let columns = [
        GridItem(.flexible(minimum: 120), spacing: 10),
        GridItem(.flexible(minimum: 120), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statsCard.padding(.horizontal)

                if model.photos.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No shared photos yet",
                        message: "Matched photo previews show up here as event members sync their cameras.",
                        systemImage: "square.grid.2x2"
                    )
                    .frame(minHeight: 280)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.photos) { match in
                            PhotoCard(
                                match: match,
                                ownerLabel: model.ownerLabel(for: match.ownerUserId)
                            )
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Shared Album")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.configure(env: env)
            await model.reload()
        }
        .refreshable { await model.reload() }
    }

    private var statsCard: some View {
        HStack(spacing: 0) {
            statTile(value: "\(model.photos.count)", label: "Shared Previews", icon: "photo.stack")
            Divider().frame(height: 36)
            statTile(value: "\(model.contributorCount)", label: "Contributors", icon: "person.2")
        }
        .padding(.vertical, 14)
        .background(Theme.softWash, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private func statTile(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(Theme.violet)
            Text(value).font(.title3).bold().foregroundStyle(Theme.ink)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
