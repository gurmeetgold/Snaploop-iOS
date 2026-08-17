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
            return "Trip member"
        }
        if let name = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let phone = participant.phoneNumber, !phone.isEmpty { return phone }
        return "Trip member"
    }

    var contributorCount: Int { Set(photos.map(\.ownerUserId)).count }
}

enum SharedFilter: String, CaseIterable, Identifiable {
    case everyone, videos, favorites
    var id: String { rawValue }
    var title: String { self == .everyone ? "Everyone" : rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .everyone: return "person.2.fill"
        case .videos: return "play.rectangle"
        case .favorites: return "star"
        }
    }
}

struct SharedAlbumView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model: SharedAlbumModel
    @State private var filter: SharedFilter = .everyone

    init(event: Event) {
        _model = StateObject(wrappedValue: SharedAlbumModel(event: event))
    }

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statsCard.padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SharedFilter.allCases) { f in
                            FilterChip(title: f.title, systemImage: f.systemImage, isSelected: filter == f) {
                                filter = f
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                if model.photos.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No shared photos yet",
                        message: "Photos show up here as people sync their cameras.",
                        systemImage: "square.grid.2x2"
                    )
                    .frame(minHeight: 280)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.photos) {
                            PhotoCard(
                                match: $0,
                                ownerLabel: model.ownerLabel(for: $0.ownerUserId)
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
            statTile(value: "\(model.photos.count)", label: "Photos & Videos", icon: "photo.stack")
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
