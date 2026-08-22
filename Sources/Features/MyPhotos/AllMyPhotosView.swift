import SwiftUI

/// Keeps the same underlying camera-library photo from appearing twice when it
/// is eligible in more than one Trip.
enum PhotoMatchDeduplication {
    static func unique(_ matches: [PhotoMatch]) -> [PhotoMatch] {
        var seen = Set<String>()
        return matches.filter { seen.insert("\(match.ownerUserId)|\(match.assetLocalId)").inserted }
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
        isLoading = true; errorMessage = nil

        let events: [Event]
        do { events = try await env.events.events(forUserId: userId) }
        catch {
            guard generation == reloadGeneration else { return }
            photos = []; favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
            errorMessage = (error as NSError).localizedDescription; isLoading = false; return
        }

        var allMatches: [PhotoMatch] = []
        var firstError: Error?
        for event in events where event.status != .deletedByOrganizer {
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            do { allMatches.append(contentsOf: try await env.matches.myPhotos(eventId: event.id, userId: userId)) }
            catch { if firstError == nil { firstError = error } }
        }

        guard generation == reloadGeneration else { return }
        photos = PhotoMatchDeduplication.unique(allMatches).sorted { $0.capturedAt > $1.capturedAt }
        favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
        errorMessage = firstError.map { ($0 as NSError).localizedDescription }
        isLoading = false
    }

    func ownerLabel(for match: PhotoMatch) -> String {
        if match.ownerUserId == session?.user?.id,
           let name = session?.user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return "Trip member"
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
        favoriteIds.remove(match.id); LocalPhotoFavoritesStore.set(false, matchId: match.id, userId: userId)
        do { try await env.matches.dismissAppearance(matchId: match.id, participantUserId: userId) }
        catch { errorMessage = "Couldn't save the Not Me correction. Pull to refresh and try again." }
    }
}

struct AllMyPhotosView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = AllMyPhotosModel()
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InsightBanner(value: "\(model.photos.count)", label: "photos found of you", systemImage: "sparkles").padding(.horizontal)
                    Text("Across all your Trips").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.horizontal)
                    if let errorMessage = model.errorMessage {
                        Label("Some Trip photos could not be refreshed. \(errorMessage)", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red).padding(.horizontal)
                    }
                    if model.photos.isEmpty && !model.isLoading {
                        ContentUnavailableViewCompat(title: "No photos of you yet", message: "As you and your Trip members sync, photos matched to you will appear here.", systemImage: "person.crop.square").frame(minHeight: 300)
                    } else {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(model.photos) { match in
                                NavigationLink {
                                    PhotoDetailView(match: match, ownerLabel: model.ownerLabel(for: match), isFavorite: model.isFavorite(match), onFavoriteChanged: { model.setFavorite($0, match: match) }, onNotMe: { Task { await model.markNotMe(match) } })
                                } label: { AllMyPhotosGridCell(match: match, isFavorite: model.isFavorite(match)) }
                                .buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 16)
                    }
                }.padding(.vertical, 16)
            }
        }
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session); await model.reload() }
        .refreshable { await model.reload() }
    }
}

private struct AllMyPhotosGridCell: View {
    let match: PhotoMatch; let isFavorite: Bool
    var body: some View {
        GeometryReader { geometry in
            ThumbnailCell(path: match.thumbnailPath)
                .frame(width: geometry.size.width, height: geometry.size.width).clipped()
                .overlay(alignment: .topTrailing) { if isFavorite { Image(systemName: "heart.fill").font(.caption).foregroundStyle(Theme.pink).padding(7) } }
        }
        .aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14)).contentShape(Rectangle()).shadow(color: Theme.ink.opacity(0.06), radius: 8, y: 4)
    }
}
