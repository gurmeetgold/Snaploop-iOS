import SwiftUI

/// Keeps the same underlying camera-library photo from appearing twice when it
/// is eligible in more than one Event.
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
    private var reloadGeneration = 0

    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        errorMessage = nil

        let events: [Event]
        do { events = try await env.events.events(forUserId: userId) }
        catch {
            guard generation == reloadGeneration else { return }
            photos = []
            favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
            errorMessage = (error as NSError).localizedDescription
            isLoading = false
            return
        }

        var allMatches: [PhotoMatch] = []
        var firstError: Error?

        for event in events where event.status != .deletedByOrganizer {
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            do {
                async let matchesTask = env.matches.myPhotos(eventId: event.id, userId: userId)
                async let membersTask = env.events.members(eventId: event.id)
                let (eventMatches, members) = try await (matchesTask, membersTask)
                let sharingEnabled = members.first(where: { $0.userId == userId })?.sharingEnabled ?? false
                allMatches.append(contentsOf: eventMatches.filter { sharingEnabled || $0.ownerUserId != userId })
            } catch AppError.notAMember {
                continue
            } catch AppError.eventNotFound {
                continue
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        guard generation == reloadGeneration else { return }
        photos = PhotoMatchDeduplication.unique(allMatches).sorted { $0.capturedAt > $1.capturedAt }
        favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
        errorMessage = firstError.map { ($0 as NSError).localizedDescription }
        isLoading = false
    }

    func ownerLabel(for match: PhotoMatch) -> String {
        match.ownerUserId == session?.user?.id ? "You" : "Event member"
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
        do { try await env.matches.dismissAppearance(matchId: match.id, participantUserId: userId) }
        catch { errorMessage = "Couldn't save the Not Me correction. Pull to refresh and try again." }
    }
}

struct AllMyPhotosView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = AllMyPhotosModel()
    @State private var filter: PhotoFilter = .all
    @State private var columnCount = 2

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: columnCount >= 6 ? 4 : 8, alignment: .top), count: columnCount)
    }

    private var filtered: [PhotoMatch] {
        switch filter {
        case .all: return model.photos
        case .favorites: return model.photos.filter { model.favoriteIds.contains($0.id) }
        }
    }

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InsightBanner(value: "\(model.photos.count)", label: "photos found of you", systemImage: "sparkles")
                        .padding(.horizontal)

                    Text("Across all your Events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)

                    HStack(spacing: 8) {
                        ForEach(PhotoFilter.allCases) { item in
                            FilterChip(
                                title: item.title,
                                systemImage: item.systemImage,
                                isSelected: filter == item
                            ) {
                                filter = item
                            }
                        }
                        Spacer()
                        Menu {
                            ForEach([2, 4, 6, 8], id: \.self) { count in
                                Button {
                                    withAnimation(.snappy) { columnCount = count }
                                } label: {
                                    Label("\(count) per row", systemImage: count == columnCount ? "checkmark" : "square.grid.3x3")
                                }
                            }
                        } label: {
                            Label("\(columnCount)", systemImage: "square.grid.3x3.fill")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(.white.opacity(0.9), in: Capsule())
                                .foregroundStyle(Theme.sunset)
                        }
                    }
                    .padding(.horizontal)

                    if let errorMessage = model.errorMessage {
                        Label("Some photos could not be refreshed. \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    if filtered.isEmpty && !model.isLoading {
                        ContentUnavailableViewCompat(
                            title: model.errorMessage == nil
                                ? (filter == .favorites ? "No favorites yet" : "No photos of you yet")
                                : "Photos unavailable",
                            message: model.errorMessage == nil
                                ? (filter == .favorites
                                    ? "Open a photo and tap Favorite to keep it here."
                                    : "SnapLoop automatically checks eligible live Events for new matched photos. You can also use Sync Now from an Event at any time.")
                                : "Pull to refresh and try again.",
                            systemImage: model.errorMessage == nil
                                ? (filter == .favorites ? "heart" : "person.crop.square")
                                : "exclamationmark.triangle"
                        )
                        .frame(minHeight: 300)
                    } else {
                        LazyVGrid(columns: columns, spacing: columnCount >= 6 ? 4 : 8) {
                            ForEach(filtered) { match in
                                NavigationLink {
                                    PhotoDetailView(
                                        match: match,
                                        ownerLabel: model.ownerLabel(for: match),
                                        isFavorite: model.isFavorite(match),
                                        onFavoriteChanged: { model.setFavorite($0, match: match) },
                                        onNotMe: { Task { await model.markNotMe(match) } }
                                    )
                                } label: {
                                    PhotoCard(
                                        match: match,
                                        ownerLabel: model.ownerLabel(for: match),
                                        isFavorite: model.isFavorite(match),
                                        compact: columnCount >= 6
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, columnCount >= 6 ? 8 : 16)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.configure(env: env, session: session)
            Task { await model.reload() }
        }
        .refreshable { await model.reload() }
    }
}
