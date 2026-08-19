import SwiftUI

/// Keeps the same underlying camera-library photo from appearing twice when it
/// is eligible in more than one event. PhotoMatch.id includes the event id, so
/// cross-event deduplication must use the owner's stable PhotoKit asset id.
enum PhotoMatchDeduplication {
    static func unique(_ matches: [PhotoMatch]) -> [PhotoMatch] {
        var seen = Set<String>()
        return matches.filter { match in
            seen.insert("\(match.ownerUserId)|\(match.assetLocalId)").inserted
        }
    }
}

@MainActor
final class AllMyPhotosModel: ObservableObject {
    @Published var photos: [PhotoMatch] = []
    @Published var favoriteIds: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var env: AppEnvironment?
    private var session: AppSession?
    private var participantLabels: [String: String] = [:]

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let events = (try? await env.events.events(forUserId: userId)) ?? []
        var allMatches: [PhotoMatch] = []
        var labels: [String: String] = [:]

        for event in events where event.status != .deletedByOrganizer {
            do {
                let eventMatches = try await env.matches.myPhotos(eventId: event.id, userId: userId)
                allMatches.append(contentsOf: eventMatches)
            } catch {
                if errorMessage == nil { errorMessage = (error as NSError).localizedDescription }
            }

            let participants = (try? await env.events.participants(eventId: event.id)) ?? []
            for participant in participants {
                let key = labelKey(eventId: event.id, userId: participant.userId)
                if let name = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    labels[key] = name
                } else if let phone = participant.phoneNumber, !phone.isEmpty {
                    labels[key] = phone
                }
            }
        }

        participantLabels = labels
        photos = PhotoMatchDeduplication.unique(allMatches).sorted { $0.capturedAt > $1.capturedAt }
        favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
    }

    func ownerLabel(for match: PhotoMatch) -> String {
        if match.ownerUserId == session?.user?.id {
            if let name = session?.user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
            if let phone = session?.user?.phoneNumber, !phone.isEmpty { return phone }
        }
        return participantLabels[labelKey(eventId: match.eventId, userId: match.ownerUserId)] ?? "Event member"
    }

    func isFavorite(_ match: PhotoMatch) -> Bool { favoriteIds.contains(match.id) }

    func setFavorite(_ favorite: Bool, match: PhotoMatch) {
        guard let userId = session?.user?.id else { return }
        LocalPhotoFavoritesStore.set(favorite, matchId: match.id, userId: userId)
        if favorite { favoriteIds.insert(match.id) } else { favoriteIds.remove(match.id) }
    }

    func markNotMe(_ match: PhotoMatch) async {
        guard let env, let userId = session?.user?.id else { return }
        photos.removeAll { $0.ownerUserId == match.ownerUserId && $0.assetLocalId == match.assetLocalId }
        favoriteIds.remove(match.id)
        LocalPhotoFavoritesStore.set(false, matchId: match.id, userId: userId)
        do {
            try await env.matches.dismissAppearance(matchId: match.id, participantUserId: userId)
        } catch {
            errorMessage = "Couldn't save the Not Me correction. Pull to refresh and try again."
        }
    }

    private func labelKey(eventId: String, userId: String) -> String { "\(eventId)|\(userId)" }
}

struct AllMyPhotosView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = AllMyPhotosModel()

    private let columns = [
        GridItem(.flexible(), spacing: 8, alignment: .top),
        GridItem(.flexible(), spacing: 8, alignment: .top)
    ]

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InsightBanner(value: "\(model.photos.count)", label: "total photos found of you", systemImage: "sparkles")
                        .padding(.horizontal)

                    if let errorMessage = model.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    if model.photos.isEmpty && !model.isLoading {
                        ContentUnavailableViewCompat(
                            title: "No photos of you yet",
                            message: "As you and other event members sync your cameras, your matched photos will appear here.",
                            systemImage: "person.crop.square"
                        )
                        .frame(minHeight: 300)
                    } else {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(model.photos) { match in
                                NavigationLink {
                                    PhotoDetailView(
                                        match: match,
                                        ownerLabel: model.ownerLabel(for: match),
                                        isFavorite: model.isFavorite(match),
                                        onFavoriteChanged: { value in model.setFavorite(value, match: match) },
                                        onNotMe: { Task { await model.markNotMe(match) } }
                                    )
                                } label: {
                                    AllMyPhotosGridCell(
                                        match: match,
                                        isFavorite: model.isFavorite(match)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .navigationTitle("Photos Found of You")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.configure(env: env, session: session)
            await model.reload()
        }
        .refreshable { await model.reload() }
    }
}

/// Fixed square cells prevent a landscape thumbnail's intrinsic dimensions
/// from changing the grid row height or drawing over a neighboring cell.
private struct AllMyPhotosGridCell: View {
    let match: PhotoMatch
    let isFavorite: Bool

    var body: some View {
        GeometryReader { geometry in
            ThumbnailCell(path: match.thumbnailPath)
                .frame(width: geometry.size.width, height: geometry.size.width)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.pink)
                            .padding(7)
                    }
                }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .shadow(color: Theme.ink.opacity(0.06), radius: 8, y: 4)
    }
}
