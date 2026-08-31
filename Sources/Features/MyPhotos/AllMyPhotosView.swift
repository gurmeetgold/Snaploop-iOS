import SwiftUI
import UIKit

private enum CachedGalleryMatches {
    private static func prefix(userId: String) -> String { "snaploop.gallery.cache.\(userId)" }
    private static func key(userId: String, faceIdentityId: String) -> String {
        "\(prefix(userId: userId)).\(faceIdentityId)"
    }

    static func load(userId: String, faceIdentityId: String) -> [PhotoMatch] {
        guard !faceIdentityId.isEmpty,
              let data = UserDefaults.standard.data(forKey: key(userId: userId, faceIdentityId: faceIdentityId)),
              let matches = try? JSONDecoder().decode([PhotoMatch].self, from: data) else { return [] }
        return matches
    }

    static func save(_ matches: [PhotoMatch], userId: String, faceIdentityId: String) {
        guard !faceIdentityId.isEmpty,
              let data = try? JSONEncoder().encode(matches) else { return }
        UserDefaults.standard.set(data, forKey: key(userId: userId, faceIdentityId: faceIdentityId))
    }

    static func purgeOtherIdentities(userId: String, keeping faceIdentityId: String?) {
        let base = prefix(userId: userId)
        let keep = faceIdentityId.flatMap { $0.isEmpty ? nil : key(userId: userId, faceIdentityId: $0) }
        for existingKey in UserDefaults.standard.dictionaryRepresentation().keys
            where existingKey == base || existingKey.hasPrefix("\(base).") {
            if existingKey != keep { UserDefaults.standard.removeObject(forKey: existingKey) }
        }
    }
}

enum PhotoMatchDeduplication {
    private static func migrationEquivalenceKey(_ match: PhotoMatch) -> String {
        let capturedMillis = Int64((match.capturedAt.timeIntervalSince1970 * 1000).rounded())
        return "\(match.ownerUserId)|\(match.assetLocalId)|\(capturedMillis)"
    }

    private static func logicalSourceKey(_ match: PhotoMatch) -> String {
        let sourceScope = match.sourceInstallationId ?? "legacy"
        return "\(match.ownerUserId)|\(sourceScope)|\(match.assetLocalId)"
    }

    static func unique(_ matches: [PhotoMatch]) -> [PhotoMatch] {
        // A one-time Change-4 rebuild can leave one legacy row beside its modern
        // source-scoped equivalent. Prefer the modern row for that exact
        // owner/asset/capture tuple, while never collapsing two real modern
        // source installations belonging to the same account.
        let modernEquivalents = Set(
            matches
                .filter { $0.sourceInstallationId != nil }
                .map(migrationEquivalenceKey)
        )

        var seen = Set<String>()
        return matches.filter { match in
            if match.sourceInstallationId == nil,
               modernEquivalents.contains(migrationEquivalenceKey(match)) {
                return false
            }
            return seen.insert(logicalSourceKey(match)).inserted
        }
    }

    static func isSameLogicalSourcePhoto(_ lhs: PhotoMatch, _ rhs: PhotoMatch) -> Bool {
        logicalSourceKey(lhs) == logicalSourceKey(rhs)
    }
}

private struct GalleryEventLoad: Sendable {
    let matches: [PhotoMatch]
    let members: [EventMember]
    let errorMessage: String?
}

@MainActor
final class AllMyPhotosModel: ObservableObject {
    @Published var photos: [PhotoMatch] = []
    @Published var favoriteIds: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var ownerNames: [String: String] = [:]
    @Published private(set) var eventNames: [String: String] = [:]

    private var env: AppEnvironment?
    private var session: AppSession?
    private var reloadGeneration = 0
    private var lastReloadAt: Date?
    private let automaticRefreshInterval: TimeInterval = 30

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
        guard let userId = session.user?.id else { return }

        let identity = session.faceProfile?.stableFaceIdentityId
        CachedGalleryMatches.purgeOtherIdentities(userId: userId, keeping: identity)
        if let identity, !identity.isEmpty, photos.isEmpty {
            photos = CachedGalleryMatches.load(userId: userId, faceIdentityId: identity)
        } else if identity == nil || identity?.isEmpty == true {
            photos = []
        }

        favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
        if let name = session.user?.displayName, !name.isEmpty { ownerNames[userId] = name }
    }

    func reload(force: Bool = false) async {
        guard let env, let userId = session?.user?.id else { return }

        if !force,
           !photos.isEmpty,
           let lastReloadAt,
           Date().timeIntervalSince(lastReloadAt) < automaticRefreshInterval {
            favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
            return
        }

        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        errorMessage = nil

        guard let faceIdentityId = session?.faceProfile?.stableFaceIdentityId,
              !faceIdentityId.isEmpty else {
            photos = []
            CachedGalleryMatches.purgeOtherIdentities(userId: userId, keeping: nil)
            favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
            isLoading = false
            return
        }

        CachedGalleryMatches.purgeOtherIdentities(userId: userId, keeping: faceIdentityId)

        let events: [Event]
        do {
            events = try await env.events.events(forUserId: userId)
        } catch {
            guard generation == reloadGeneration else { return }
            favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
            errorMessage = (error as NSError).localizedDescription
            isLoading = false
            return
        }

        let matchRepository = env.matches
        let eventRepository = env.events
        let activeEvents = events.filter { $0.status != .deletedByOrganizer }
        eventNames = Dictionary(uniqueKeysWithValues: activeEvents.map { ($0.id, $0.name) })

        let eventLoads = await withTaskGroup(of: GalleryEventLoad.self, returning: [GalleryEventLoad].self) { group in
            for event in activeEvents {
                group.addTask {
                    do {
                        async let matchesTask = matchRepository.myPhotos(eventId: event.id, userId: userId)
                        async let membersTask = eventRepository.members(eventId: event.id)
                        let (matches, members) = try await (matchesTask, membersTask)
                        return GalleryEventLoad(matches: matches, members: members, errorMessage: nil)
                    } catch AppError.notAMember {
                        return GalleryEventLoad(matches: [], members: [], errorMessage: nil)
                    } catch AppError.eventNotFound {
                        return GalleryEventLoad(matches: [], members: [], errorMessage: nil)
                    } catch {
                        return GalleryEventLoad(
                            matches: [],
                            members: [],
                            errorMessage: (error as NSError).localizedDescription
                        )
                    }
                }
            }

            var loaded: [GalleryEventLoad] = []
            loaded.reserveCapacity(activeEvents.count)
            for await item in group { loaded.append(item) }
            return loaded
        }

        guard !Task.isCancelled, generation == reloadGeneration else { return }
        guard session?.faceProfile?.stableFaceIdentityId == faceIdentityId else {
            photos = []
            isLoading = false
            return
        }

        var allMatches: [PhotoMatch] = []
        var firstErrorMessage: String?
        var names = ownerNames
        if let ownName = session?.user?.displayName, !ownName.isEmpty { names[userId] = ownName }

        for load in eventLoads {
            if firstErrorMessage == nil { firstErrorMessage = load.errorMessage }
            let sharingEnabled = load.members.first(where: { $0.userId == userId })?.sharingEnabled ?? false
            allMatches.append(contentsOf: load.matches.filter { sharingEnabled || $0.ownerUserId != userId })

            for member in load.members where names[member.userId] == nil {
                if member.userId == userId,
                   let ownName = session?.user?.displayName,
                   !ownName.isEmpty {
                    names[member.userId] = ownName
                } else if let displayName = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !displayName.isEmpty {
                    names[member.userId] = displayName
                }
            }
        }

        let refreshed = PhotoMatchDeduplication.unique(allMatches).sorted { $0.capturedAt > $1.capturedAt }
        photos = refreshed
        ownerNames = names
        CachedGalleryMatches.save(refreshed, userId: userId, faceIdentityId: faceIdentityId)
        favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
        errorMessage = firstErrorMessage
        lastReloadAt = Date()
        isLoading = false
    }

    func ownerLabel(for match: PhotoMatch) -> String {
        if match.ownerUserId == session?.user?.id { return session?.user?.displayName ?? "You" }
        return ownerNames[match.ownerUserId] ?? "Event member"
    }

    func eventLabel(for match: PhotoMatch) -> String {
        eventNames[match.eventId] ?? "Event"
    }

    func isFavorite(_ match: PhotoMatch) -> Bool { favoriteIds.contains(match.id) }

    func setFavorite(_ favorite: Bool, match: PhotoMatch) {
        guard let userId = session?.user?.id else { return }
        LocalPhotoFavoritesStore.set(favorite, matchId: match.id, userId: userId)
        if favorite { favoriteIds.insert(match.id) } else { favoriteIds.remove(match.id) }
    }

    func markNotMe(_ match: PhotoMatch) async {
        guard let env, let userId = session?.user?.id else { return }
        photos.removeAll { PhotoMatchDeduplication.isSameLogicalSourcePhoto($0, match) }
        if let identity = session?.faceProfile?.stableFaceIdentityId, !identity.isEmpty {
            CachedGalleryMatches.save(photos, userId: userId, faceIdentityId: identity)
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
    @State private var columnCount = 2
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var bulkBusy = false
    @State private var bulkMessage: String?
    @State private var bulkShareImages: [UIImage] = []
    @State private var showBulkShare = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: columnCount >= 6 ? 4 : 8, alignment: .top), count: columnCount)
    }

    private var filtered: [PhotoMatch] {
        switch filter {
        case .all: return model.photos
        case .favorites: return model.photos.filter { model.favoriteIds.contains($0.id) }
        }
    }

    private var selectedMatches: [PhotoMatch] {
        filtered.filter { selectedIDs.contains($0.id) }
    }

    private var allSelectedAreFavorites: Bool {
        !selectedMatches.isEmpty && selectedMatches.allSatisfy { model.isFavorite($0) }
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

                        if isSelecting {
                            Text("\(selectedIDs.count) selected")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Button("Cancel") { endSelection() }
                                .font(.subheadline.bold())
                        } else {
                            Button("Select") { beginSelection() }
                                .font(.subheadline.bold())
                                .disabled(filtered.isEmpty)

                            Menu {
                                ForEach([2, 3, 4, 6], id: \.self) { count in
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
                                    .frame(minHeight: 44)
                                    .background(Theme.surface, in: Capsule())
                                    .overlay { Capsule().strokeBorder(Theme.divider) }
                                    .foregroundStyle(Theme.violet)
                                    .contentShape(Capsule())
                            }
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
                                        : "SnapLoop automatically checks eligible Events for new matched photos. You can also use Scan Photos from an Event at any time.")
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
                                if isSelecting {
                                    Button {
                                        toggleSelection(match.id)
                                    } label: {
                                        PhotoCard(
                                            match: match,
                                            ownerLabel: model.ownerLabel(for: match),
                                            isFavorite: model.isFavorite(match),
                                            compact: columnCount >= 6,
                                            selectionMode: true,
                                            isSelected: selectedIDs.contains(match.id)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink {
                                        PhotoDetailView(
                                            matches: filtered,
                                            initialMatchID: match.id,
                                            ownerLabel: { model.ownerLabel(for: $0) },
                                            eventLabel: { model.eventLabel(for: $0) },
                                            isFavorite: { model.isFavorite($0) },
                                            onFavoriteChanged: { item, value in model.setFavorite(value, match: item) }
                                        )
                                    } label: {
                                        PhotoCard(match: match, ownerLabel: model.ownerLabel(for: match), isFavorite: model.isFavorite(match), compact: columnCount >= 6)
                                    }
                                    .buttonStyle(.plain)
                                }
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
        .toolbar {
            if !isSelecting {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.reload(force: true) }
                    } label: {
                        if model.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(model.isLoading)
                    .accessibilityLabel("Refresh My Photos")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                PhotoSelectionToolbar(
                    selectedCount: selectedIDs.count,
                    allFavorites: allSelectedAreFavorites,
                    busy: bulkBusy,
                    message: bulkMessage,
                    onSave: { Task { await saveSelected() } },
                    onShare: { Task { await shareSelected() } },
                    onFavorite: { favoriteSelected() }
                )
            }
        }
        .sheet(isPresented: $showBulkShare) {
            ActivityView(items: bulkShareImages.map { $0 as Any })
        }
        .onAppear {
            model.configure(env: env, session: session)
            Task { await model.reload() }
        }
        .refreshable { await model.reload(force: true) }
        .onChange(of: filter) { _, _ in selectedIDs.removeAll(); bulkMessage = nil }
        .onChange(of: model.photos.map(\.id)) { _, ids in selectedIDs.formIntersection(Set(ids)) }
    }

    private func beginSelection() {
        isSelecting = true
        selectedIDs.removeAll()
        bulkMessage = nil
    }

    private func endSelection() {
        isSelecting = false
        selectedIDs.removeAll()
        bulkMessage = nil
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
        bulkMessage = nil
    }

    private func favoriteSelected() {
        guard !selectedMatches.isEmpty else { return }
        let nextValue = !allSelectedAreFavorites
        for match in selectedMatches { model.setFavorite(nextValue, match: match) }
        bulkMessage = nextValue ? "Added to Favorites." : "Removed from Favorites."
        if filter == .favorites && !nextValue { selectedIDs.removeAll() }
    }

    @MainActor
    private func saveSelected() async {
        guard !selectedMatches.isEmpty else { return }
        bulkBusy = true
        bulkMessage = nil
        defer { bulkBusy = false }
        do {
            let images = await PhotoBulkActions.loadImages(for: selectedMatches)
            guard !images.isEmpty else { throw AppError.originalUnavailable }
            try await PhotoBulkActions.saveToPhotoLibrary(images)
            bulkMessage = images.count == 1 ? "Saved 1 photo." : "Saved \(images.count) photos."
        } catch AppError.photoLibraryAccessDenied {
            bulkMessage = "Allow SnapLoop to add photos in iPhone Settings."
        } catch {
            bulkMessage = "Some photos couldn't be saved."
        }
    }

    @MainActor
    private func shareSelected() async {
        guard !selectedMatches.isEmpty else { return }
        bulkBusy = true
        bulkMessage = nil
        let images = await PhotoBulkActions.loadImages(for: selectedMatches)
        bulkBusy = false
        guard !images.isEmpty else {
            bulkMessage = "Selected photos couldn't be prepared."
            return
        }
        bulkShareImages = images
        showBulkShare = true
    }
}
