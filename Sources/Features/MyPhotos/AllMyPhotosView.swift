import SwiftUI

private enum CachedGalleryMatches {
    private static func prefix(userId: String) -> String { "snaploop.gallery.cache.\(userId)" }
    private static func key(userId: String, faceRevision: String) -> String {
        "\(prefix(userId: userId)).\(faceRevision)"
    }

    static func load(userId: String, faceRevision: String) -> [PhotoMatch] {
        guard !faceRevision.isEmpty,
              let data = UserDefaults.standard.data(forKey: key(userId: userId, faceRevision: faceRevision)),
              let matches = try? JSONDecoder().decode([PhotoMatch].self, from: data) else { return [] }
        return matches
    }

    static func save(_ matches: [PhotoMatch], userId: String, faceRevision: String) {
        guard !faceRevision.isEmpty,
              let data = try? JSONEncoder().encode(matches) else { return }
        UserDefaults.standard.set(data, forKey: key(userId: userId, faceRevision: faceRevision))
    }

    /// Face-derived Gallery metadata must never cross a Face Setup identity
    /// boundary. Remove legacy/user-only caches and every prior Face Setup
    /// revision as soon as the current account/profile is configured.
    static func purgeOtherRevisions(userId: String, keeping faceRevision: String?) {
        let base = prefix(userId: userId)
        let keep = faceRevision.flatMap { $0.isEmpty ? nil : key(userId: userId, faceRevision: $0) }
        for existingKey in UserDefaults.standard.dictionaryRepresentation().keys
            where existingKey == base || existingKey.hasPrefix("\(base).") {
            if existingKey != keep { UserDefaults.standard.removeObject(forKey: existingKey) }
        }
    }
}

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
    @Published private(set) var ownerNames: [String: String] = [:]
    private var env: AppEnvironment?
    private var session: AppSession?
    private var reloadGeneration = 0

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
        guard let userId = session.user?.id else { return }

        let revision = session.faceProfile?.faceProfileRevision
        CachedGalleryMatches.purgeOtherRevisions(userId: userId, keeping: revision)
        if let revision, !revision.isEmpty, photos.isEmpty {
            photos = CachedGalleryMatches.load(userId: userId, faceRevision: revision)
        } else if revision == nil || revision?.isEmpty == true {
            photos = []
        }

        favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
        if let name = session.user?.displayName, !name.isEmpty { ownerNames[userId] = name }
    }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        errorMessage = nil

        guard let faceRevision = session?.faceProfile?.faceProfileRevision,
              !faceRevision.isEmpty else {
            photos = []
            CachedGalleryMatches.purgeOtherRevisions(userId: userId, keeping: nil)
            favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
            isLoading = false
            return
        }

        CachedGalleryMatches.purgeOtherRevisions(userId: userId, keeping: faceRevision)

        let events: [Event]
        do { events = try await env.events.events(forUserId: userId) }
        catch {
            guard generation == reloadGeneration else { return }
            favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
            errorMessage = (error as NSError).localizedDescription
            isLoading = false
            return
        }

        var allMatches: [PhotoMatch] = []
        var firstError: Error?
        var names = ownerNames
        if let ownName = session?.user?.displayName, !ownName.isEmpty { names[userId] = ownName }

        for event in events where event.status != .deletedByOrganizer {
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            do {
                async let matchesTask = env.matches.myPhotos(eventId: event.id, userId: userId)
                async let membersTask = env.events.members(eventId: event.id)
                let (eventMatches, members) = try await (matchesTask, membersTask)
                let sharingEnabled = members.first(where: { $0.userId == userId })?.sharingEnabled ?? false
                allMatches.append(contentsOf: eventMatches.filter { sharingEnabled || $0.ownerUserId != userId })

                for member in members where names[member.userId] == nil {
                    if member.userId == userId, let ownName = session?.user?.displayName, !ownName.isEmpty {
                        names[member.userId] = ownName
                    } else if let user = try? await env.users.fetch(userId: member.userId),
                              let displayName = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !displayName.isEmpty {
                        names[member.userId] = displayName
                    }
                }
            } catch AppError.notAMember {
                continue
            } catch AppError.eventNotFound {
                continue
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        guard generation == reloadGeneration else { return }
        // If Face Setup changed while network work was in flight, discard this
        // entire response rather than caching results under the new identity.
        guard session?.faceProfile?.faceProfileRevision == faceRevision else {
            photos = []
            isLoading = false
            return
        }

        let refreshed = PhotoMatchDeduplication.unique(allMatches).sorted { $0.capturedAt > $1.capturedAt }
        photos = refreshed
        ownerNames = names
        CachedGalleryMatches.save(refreshed, userId: userId, faceRevision: faceRevision)
        favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
        errorMessage = firstError.map { ($0 as NSError).localizedDescription }
        isLoading = false
    }

    func ownerLabel(for match: PhotoMatch) -> String {
        if match.ownerUserId == session?.user?.id { return session?.user?.displayName ?? "You" }
        return ownerNames[match.ownerUserId] ?? "Event member"
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
        if let revision = session?.faceProfile?.faceProfileRevision, !revision.isEmpty {
            CachedGalleryMatches.save(photos, userId: userId, faceRevision: revision)
        }
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
    @State private var columnCount = 3

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
                            FilterChip(title: item.title, systemImage: item.systemImage, isSelected: filter == item) {
                                filter = item
                            }
                        }
                        Spacer()
                        Menu {
                            ForEach([2, 3, 4, 6], id: \.self) { count in
                                Button {
                                    withAnimation(.snappy) { columnCount = count }
                                } label: {
                                    Label("\(count) per row", systemImage: count == columnCount ? "checkmark" : "square.grid.3x3")
                                }
                            }
                        } label: {
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.subheadline.bold())
                                .padding(11)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.divider)
                                }
                                .foregroundStyle(Theme.lilac)
                        }
                    }
                    .padding(.horizontal)

                    if let errorMessage = model.errorMessage {
                        Label("Some photos could not be refreshed. \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    if filtered.isEmpty {
                        if model.isLoading {
                            VStack(spacing: 12) {
                                ProgressView().tint(Theme.lilac)
                                Text("Refreshing your photos…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                        } else {
                            ContentUnavailableViewCompat(
                                title: model.errorMessage == nil
                                    ? (filter == .favorites ? "No favorites yet" : "No photos of you yet")
                                    : "Photos unavailable",
                                message: model.errorMessage == nil
                                    ? (filter == .favorites
                                        ? "Open a photo and tap Favorite to keep it here."
                                        : "SnapLoop automatically checks eligible live Events for new matched photos. You can also use Sync Camera from an Event at any time.")
                                    : "Pull to refresh and try again.",
                                systemImage: model.errorMessage == nil
                                    ? (filter == .favorites ? "heart" : "person.crop.square")
                                    : "exclamationmark.triangle"
                            )
                            .frame(minHeight: 300)
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: columnCount >= 6 ? 4 : 8) {
                            ForEach(filtered) { match in
                                NavigationLink {
                                    PhotoDetailView(
                                        matches: filtered,
                                        initialMatchID: match.id,
                                        ownerLabel: { model.ownerLabel(for: $0) },
                                        isFavorite: { model.isFavorite($0) },
                                        onFavoriteChanged: { item, value in model.setFavorite(value, match: item) },
                                        onNotMe: { item in Task { await model.markNotMe(item) } }
                                    )
                                } label: {
                                    PhotoCard(match: match, ownerLabel: model.ownerLabel(for: match), isFavorite: model.isFavorite(match), compact: columnCount >= 6)
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
