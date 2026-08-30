import FirebaseFunctions
import FirebaseStorage
import ImageIO
import Photos
import SwiftUI
import UIKit

private struct EventGalleryCacheEnvelope: Codable {
    let photos: [PhotoMatch]
    let members: [EventMember]
    let savedAt: Date
}

private enum CachedEventGallery {
    private static func prefix(userId: String, eventId: String) -> String {
        "snaploop.event.gallery.cache.\(userId).\(eventId)"
    }

    private static func key(userId: String, eventId: String, faceIdentityId: String) -> String {
        "\(prefix(userId: userId, eventId: eventId)).\(faceIdentityId)"
    }

    static func load(userId: String, eventId: String, faceIdentityId: String) -> EventGalleryCacheEnvelope? {
        guard !faceIdentityId.isEmpty,
              let data = UserDefaults.standard.data(forKey: key(userId: userId, eventId: eventId, faceIdentityId: faceIdentityId)) else {
            return nil
        }
        return try? JSONDecoder().decode(EventGalleryCacheEnvelope.self, from: data)
    }

    static func save(
        photos: [PhotoMatch],
        members: [EventMember],
        userId: String,
        eventId: String,
        faceIdentityId: String
    ) {
        guard !faceIdentityId.isEmpty else { return }
        let envelope = EventGalleryCacheEnvelope(photos: photos, members: members, savedAt: Date())
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        UserDefaults.standard.set(data, forKey: key(userId: userId, eventId: eventId, faceIdentityId: faceIdentityId))
    }

    static func purgeOtherIdentities(userId: String, eventId: String, keeping faceIdentityId: String?) {
        let base = prefix(userId: userId, eventId: eventId)
        let keep = faceIdentityId.flatMap {
            $0.isEmpty ? nil : key(userId: userId, eventId: eventId, faceIdentityId: $0)
        }
        for existingKey in UserDefaults.standard.dictionaryRepresentation().keys
            where existingKey == base || existingKey.hasPrefix("\(base).") {
            if existingKey != keep { UserDefaults.standard.removeObject(forKey: existingKey) }
        }
    }
}

@MainActor
final class MyPhotosModel: ObservableObject {
    @Published var photos: [PhotoMatch] = []
    @Published var members: [EventMember] = []
    @Published var favoriteIds: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var env: AppEnvironment?
    private var session: AppSession?
    private var reloadGeneration = 0
    private var lastReloadAt: Date?
    private let automaticRefreshInterval: TimeInterval = 30
    let event: Event

    init(event: Event) { self.event = event }

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
        guard let userId = session.user?.id else { return }

        let identity = session.faceProfile?.stableFaceIdentityId
        CachedEventGallery.purgeOtherIdentities(userId: userId, eventId: event.id, keeping: identity)
        if photos.isEmpty,
           let identity,
           !identity.isEmpty,
           let cached = CachedEventGallery.load(userId: userId, eventId: event.id, faceIdentityId: identity) {
            photos = cached.photos
            members = cached.members
            lastReloadAt = cached.savedAt
        }
        favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
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
        defer {
            if generation == reloadGeneration { isLoading = false }
        }

        async let photosResult = env.matches.myPhotos(eventId: event.id, userId: userId)
        async let membersResult = env.events.members(eventId: event.id)

        var loadedPhotos: [PhotoMatch]?
        var loadedMembers: [EventMember]?
        var firstError: Error?

        do { loadedPhotos = try await photosResult }
        catch { firstError = error }

        do { loadedMembers = try await membersResult }
        catch { if firstError == nil { firstError = error } }

        guard generation == reloadGeneration, session?.user?.id == userId else { return }

        if let loadedMembers { members = loadedMembers }
        if let loadedPhotos {
            let sharingEnabled = members.first(where: { $0.userId == userId })?.sharingEnabled ?? false
            photos = loadedPhotos.filter { sharingEnabled || $0.ownerUserId != userId }
        }

        favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
        errorMessage = firstError.map { ($0 as NSError).localizedDescription }
        lastReloadAt = Date()

        if let identity = session?.faceProfile?.stableFaceIdentityId, !identity.isEmpty {
            CachedEventGallery.save(
                photos: photos,
                members: members,
                userId: userId,
                eventId: event.id,
                faceIdentityId: identity
            )
        }
    }

    func ownerLabel(for userId: String) -> String {
        if userId == session?.user?.id { return "You" }
        if let member = members.first(where: { $0.userId == userId }),
           let name = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "Event member"
    }

    func isFavorite(_ match: PhotoMatch) -> Bool { favoriteIds.contains(match.id) }

    func setFavorite(_ favorite: Bool, match: PhotoMatch) {
        guard let userId = session?.user?.id else { return }
        LocalPhotoFavoritesStore.set(favorite, matchId: match.id, userId: userId)
        if favorite { favoriteIds.insert(match.id) } else { favoriteIds.remove(match.id) }
    }

    func markNotMe(_ match: PhotoMatch) async {
        guard let env, let userId = session?.user?.id else { return }
        photos.removeAll { $0.id == match.id }
        favoriteIds.remove(match.id)
        LocalPhotoFavoritesStore.set(false, matchId: match.id, userId: userId)

        if let identity = session?.faceProfile?.stableFaceIdentityId, !identity.isEmpty {
            CachedEventGallery.save(
                photos: photos,
                members: members,
                userId: userId,
                eventId: event.id,
                faceIdentityId: identity
            )
        }

        do { try await env.matches.dismissAppearance(matchId: match.id, participantUserId: userId) }
        catch { errorMessage = "Couldn't save the Not Me correction. Pull to refresh and try again." }
    }
}

enum PhotoFilter: String, CaseIterable, Identifiable {
    case all, favorites
    var id: String { rawValue }
    var title: String { self == .all ? "All" : "Favorites" }
    var systemImage: String { self == .all ? "square.grid.2x2" : "heart.fill" }
}

struct MyPhotosView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: MyPhotosModel
    @State private var filter: PhotoFilter = .all
    @State private var columnCount = 2
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var bulkBusy = false
    @State private var bulkMessage: String?
    @State private var bulkShareImages: [UIImage] = []
    @State private var showBulkShare = false

    init(event: Event) { _model = StateObject(wrappedValue: MyPhotosModel(event: event)) }

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

                    HStack(spacing: 8) {
                        ForEach(PhotoFilter.allCases) { f in
                            FilterChip(title: f.title, systemImage: f.systemImage, isSelected: filter == f) { filter = f }
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
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red).padding(.horizontal)
                    }

                    if filtered.isEmpty && !model.isLoading {
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
                        .frame(minHeight: 280)
                    } else {
                        LazyVGrid(columns: columns, spacing: columnCount >= 6 ? 4 : 8) {
                            ForEach(filtered) { match in
                                if isSelecting {
                                    Button {
                                        toggleSelection(match.id)
                                    } label: {
                                        PhotoCard(
                                            match: match,
                                            ownerLabel: model.ownerLabel(for: match.ownerUserId),
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
                                            ownerLabel: { model.ownerLabel(for: $0.ownerUserId) },
                                            eventLabel: { _ in model.event.name },
                                            isFavorite: { model.isFavorite($0) },
                                            onFavoriteChanged: { item, value in model.setFavorite(value, match: item) },
                                            onNotMe: { item in Task { await model.markNotMe(item) } }
                                        )
                                    } label: {
                                        PhotoCard(
                                            match: match,
                                            ownerLabel: model.ownerLabel(for: match.ownerUserId),
                                            isFavorite: model.isFavorite(match),
                                            compact: columnCount >= 6
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, columnCount >= 6 ? 8 : 16)
                    }
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("My Photos")
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
        .task {
            model.configure(env: env, session: session)
            await model.reload()
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

struct PhotoCard: View {
    let match: PhotoMatch
    var ownerLabel: String = "Event member"
    var isFavorite = false
    var compact = false
    var selectionMode = false
    var isSelected = false

    var body: some View {
        GeometryReader { geometry in
            ThumbnailCell(path: match.thumbnailPath)
                .frame(width: geometry.size.width, height: geometry.size.width)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if selectionMode {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(compact ? .caption : .title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(isSelected ? Color.white : Color.white, isSelected ? Theme.coral : Color.black.opacity(0.35))
                            .padding(compact ? 3 : 7)
                            .shadow(radius: 2)
                    } else if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(compact ? .system(size: 8) : .caption)
                            .foregroundStyle(Theme.pink)
                            .padding(compact ? 3 : 7)
                    }
                }
                .overlay {
                    if selectionMode && isSelected {
                        RoundedRectangle(cornerRadius: compact ? 6 : 14, style: .continuous)
                            .strokeBorder(Theme.coral, lineWidth: compact ? 2 : 3)
                    }
                }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 14, style: .continuous))
        .shadow(color: Theme.ink.opacity(compact ? 0 : 0.06), radius: 8, y: 4)
        .contentShape(Rectangle())
        .accessibilityLabel(selectionMode
            ? "\(isSelected ? "Selected" : "Not selected") photo taken by \(ownerLabel)"
            : "Photo taken by \(ownerLabel)")
    }
}

@MainActor
final class StorageThumbnailLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private let maxPixelSize: Int
    private var loadedPath: String?

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    private static let compressedDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 32
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    init(maxPixelSize: Int = 640) {
        self.maxPixelSize = max(320, maxPixelSize)
    }

    func load(path: String?) async {
        guard let path, !path.isEmpty else {
            image = nil
            failed = true
            loadedPath = nil
            return
        }

        if let cached = Self.cachedImage(path: path, maxPixelSize: maxPixelSize) {
            image = cached
            failed = false
            loadedPath = path
            return
        }

        if maxPixelSize > 640,
           let preview = Self.cachedImage(path: path, maxPixelSize: 640) {
            image = preview
        } else if loadedPath != path {
            image = nil
        }
        loadedPath = path
        failed = false

        do {
            let decoded = try await Self.image(path: path, maxPixelSize: maxPixelSize)
            try Task.checkCancellation()
            guard loadedPath == path else { return }
            image = decoded
        } catch is CancellationError {
            return
        } catch {
            guard loadedPath == path else { return }
            Log.events.error("Matched photo preview load failed: \(String(describing: error), privacy: .public)")
            failed = true
        }
    }

    static func image(path: String?, maxPixelSize: Int = 2560) async throws -> UIImage {
        guard let path, !path.isEmpty else { throw AppError.originalUnavailable }
        let target = max(320, maxPixelSize)

        if let cached = cachedImage(path: path, maxPixelSize: target) { return cached }

        let data: Data
        if let cachedData = compressedDataCache.object(forKey: path as NSString) {
            data = cachedData as Data
        } else {
            data = try await fetchData(path: path)
            compressedDataCache.setObject(data as NSData, forKey: path as NSString, cost: data.count)
        }

        guard let decoded = downsample(data: data, maxPixelSize: target) else {
            throw AppError.originalUnavailable
        }
        store(decoded, path: path, maxPixelSize: target)
        return decoded
    }

    static func prefetch(paths: [String], maxPixelSize: Int = 2048) async {
        for path in Array(paths.prefix(2)) where cachedImage(path: path, maxPixelSize: maxPixelSize) == nil {
            do { _ = try await image(path: path, maxPixelSize: maxPixelSize) }
            catch { continue }
        }
    }

    private static func cachedImage(path: String, maxPixelSize: Int) -> UIImage? {
        imageCache.object(forKey: cacheKey(path: path, maxPixelSize: maxPixelSize) as NSString)
    }

    private static func cacheKey(path: String, maxPixelSize: Int) -> String {
        "\(maxPixelSize)::\(path)"
    }

    private static func fetchData(path: String) async throws -> Data {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                Storage.storage().reference(withPath: path).getData(maxSize: 12 * 1024 * 1024) { data, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let data else { continuation.resume(throwing: AppError.originalUnavailable); return }
                    continuation.resume(returning: data)
                }
            }
        } catch {
            return try await authorizedFallbackData(for: path)
        }
    }

    private static func authorizedFallbackData(for path: String) async throws -> Data {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 6,
              parts[0] == "events",
              parts[2] == "photos",
              parts[5] == "thumbnail.jpg" else {
            throw AppError.originalUnavailable
        }

        let eventId = parts[1]
        let photoId = parts[4]
        let raw: Any = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            Functions.functions().httpsCallable("getMatchedThumbnail").call([
                "eventId": eventId,
                "photoId": photoId,
            ]) { result, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: result?.data as Any)
            }
        }

        guard let wrapper = raw as? [String: Any],
              let base64 = wrapper["base64"] as? String,
              let data = Data(base64Encoded: base64),
              !data.isEmpty else {
            throw AppError.originalUnavailable
        }
        return data
    }

    private static func downsample(data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func store(_ image: UIImage, path: String, maxPixelSize: Int) {
        let decodedCost: Int
        if let cgImage = image.cgImage { decodedCost = cgImage.bytesPerRow * cgImage.height }
        else { decodedCost = 4 * Int(image.size.width * image.size.height) }
        imageCache.setObject(
            image,
            forKey: cacheKey(path: path, maxPixelSize: maxPixelSize) as NSString,
            cost: decodedCost
        )
    }
}

struct ThumbnailCell: View {
    let path: String?
    @StateObject private var loader = StorageThumbnailLoader(maxPixelSize: 640)

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.softWash).overlay {
                    if loader.failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
                    else { ProgressView() }
                }
            }
        }
        .clipped()
        .task(id: path) { await loader.load(path: path) }
    }
}

enum PhotoBulkActions {
    static func loadImages(for matches: [PhotoMatch]) async -> [UIImage] {
        var images: [UIImage] = []
        for match in matches {
            guard !Task.isCancelled else { break }
            if let image = try? await StorageThumbnailLoader.image(path: match.thumbnailPath, maxPixelSize: 2560) {
                images.append(image)
            }
        }
        return images
    }

    @MainActor
    static func saveToPhotoLibrary(_ images: [UIImage]) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw AppError.photoLibraryAccessDenied
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                for image in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: AppError.originalUnavailable) }
            }
        }
    }
}

struct PhotoSelectionToolbar: View {
    let selectedCount: Int
    let allFavorites: Bool
    let busy: Bool
    let message: String?
    let onSave: () -> Void
    let onShare: () -> Void
    let onFavorite: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 36) {
                selectionAction("square.and.arrow.down", accessibility: "Save selected photos", action: onSave)
                selectionAction("square.and.arrow.up", accessibility: "Share selected photos", action: onShare)
                selectionAction(allFavorites ? "heart.fill" : "heart", accessibility: allFavorites ? "Remove selected photos from Favorites" : "Favorite selected photos", action: onFavorite)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func selectionAction(_ systemImage: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView() }
                else { Image(systemName: systemImage).font(.title3.weight(.semibold)) }
            }
            .frame(width: 48, height: 38)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .disabled(selectedCount == 0 || busy)
        .opacity(selectedCount == 0 ? 0.35 : 1)
        .accessibilityLabel(accessibility)
    }
}

struct PhotoDetailView: View {
    let matches: [PhotoMatch]
    let ownerLabel: (PhotoMatch) -> String
    let eventLabel: (PhotoMatch) -> String
    let isFavorite: (PhotoMatch) -> Bool
    let onFavoriteChanged: (PhotoMatch, Bool) -> Void
    let onNotMe: (PhotoMatch) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int
    @State private var chromeVisible = true
    @State private var currentPageZoomed = false
    @State private var favoriteOverrides: [String: Bool] = [:]
    @State private var statusMessage: String?
    @State private var shareImage: UIImage?
    @State private var showShareSheet = false
    @State private var confirmNotMe = false
    @State private var actionBusy = false
    @State private var pagerDrag: CGSize = .zero
    @State private var isSettlingPage = false

    init(
        matches: [PhotoMatch],
        initialMatchID: String,
        ownerLabel: @escaping (PhotoMatch) -> String,
        eventLabel: @escaping (PhotoMatch) -> String,
        isFavorite: @escaping (PhotoMatch) -> Bool,
        onFavoriteChanged: @escaping (PhotoMatch, Bool) -> Void,
        onNotMe: @escaping (PhotoMatch) -> Void
    ) {
        self.matches = matches
        self.ownerLabel = ownerLabel
        self.eventLabel = eventLabel
        self.isFavorite = isFavorite
        self.onFavoriteChanged = onFavoriteChanged
        self.onNotMe = onNotMe
        let initialIndex = matches.firstIndex(where: { $0.id == initialMatchID }) ?? 0
        _selectedIndex = State(initialValue: initialIndex)
    }

    private var currentMatch: PhotoMatch? {
        matches.indices.contains(selectedIndex) ? matches[selectedIndex] : matches.first
    }

    private var currentFavorite: Bool {
        guard let currentMatch else { return false }
        return favoriteOverrides[currentMatch.id] ?? isFavorite(currentMatch)
    }

    private var visibleIndices: [Int] {
        guard !matches.isEmpty else { return [] }
        return [selectedIndex - 1, selectedIndex, selectedIndex + 1]
            .filter { matches.indices.contains($0) }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let horizontal = horizontalOffset(width: width)
            let vertical = verticalDismissOffset

            ZStack {
                Color.black.ignoresSafeArea()

                ZStack {
                    ForEach(visibleIndices, id: \.self) { index in
                        HorizontalPhotoPage(
                            match: matches[index],
                            onTap: {
                                guard !isSettlingPage else { return }
                                withAnimation(.easeInOut(duration: 0.18)) { chromeVisible.toggle() }
                            },
                            onZoomChanged: { zoomed in
                                if index == selectedIndex { currentPageZoomed = zoomed }
                            }
                        )
                        .frame(width: width, height: proxy.size.height)
                        .offset(x: CGFloat(index - selectedIndex) * width + horizontal)
                    }
                }
                .offset(y: vertical)
                .scaleEffect(1 - min(vertical / max(proxy.size.height, 1), 0.08))

                if chromeVisible, let currentMatch {
                    VStack(spacing: 0) {
                        HStack {
                            Button { dismiss() } label: {
                                Image(systemName: "chevron.left")
                                    .font(.title3.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(.black.opacity(0.42), in: Circle())
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Text("\(selectedIndex + 1) / \(matches.count)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(.black.opacity(0.42), in: Capsule())
                        }
                        .padding(.horizontal, 16)
                        .safeAreaPadding(.top, 8)

                        Spacer()

                        VStack(spacing: 10) {
                            Text(compactMetadata(for: currentMatch))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.88))
                                .lineLimit(1)

                            HStack(spacing: 30) {
                                detailAction("square.and.arrow.down", accessibility: "Save photo") { Task { await saveCurrent() } }
                                detailAction("square.and.arrow.up", accessibility: "Share photo") { Task { await shareCurrent() } }
                                detailAction(currentFavorite ? "heart.fill" : "heart", accessibility: currentFavorite ? "Remove from Favorites" : "Favorite photo") { toggleFavorite() }
                                detailAction("person.crop.circle.badge.xmark", accessibility: "Not Me", destructive: true) { confirmNotMe = true }
                            }
                            .disabled(actionBusy)

                            if actionBusy {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.8)
                            } else if let statusMessage {
                                Text(statusMessage)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.82))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .safeAreaPadding(.bottom, 10)
                        .background(.black.opacity(0.48))
                    }
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(pagerGesture(width: width))
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showShareSheet) {
            if let shareImage { ActivityView(items: [shareImage]) }
        }
        .confirmationDialog("This isn't you?", isPresented: $confirmNotMe, titleVisibility: .visible) {
            Button("Not Me", role: .destructive) {
                if let currentMatch {
                    onNotMe(currentMatch)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SnapLoop will hide this photo and record the false match so matching can improve.")
        }
        .task { await prefetchAdjacent(to: selectedIndex) }
        .onChange(of: selectedIndex) { _, newValue in
            currentPageZoomed = false
            statusMessage = nil
            Task { await prefetchAdjacent(to: newValue) }
        }
    }

    private func compactMetadata(for match: PhotoMatch) -> String {
        "\(prefix3(ownerLabel(match))) · \(prefix3(eventLabel(match))) · \(DateFormatting.compactNumeric(match.capturedAt))"
    }

    private func prefix3(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(3))
    }

    private var verticalDismissOffset: CGFloat {
        guard !currentPageZoomed else { return 0 }
        let y = pagerDrag.height
        let x = abs(pagerDrag.width)
        guard y > 0, y > x * 1.12 else { return 0 }
        return y
    }

    private func horizontalOffset(width: CGFloat) -> CGFloat {
        guard !currentPageZoomed else { return 0 }
        let x = pagerDrag.width
        let y = abs(pagerDrag.height)
        guard abs(x) > y * 0.88 else { return 0 }

        let movingPastFirst = selectedIndex == 0 && x > 0
        let movingPastLast = selectedIndex == matches.count - 1 && x < 0
        return (movingPastFirst || movingPastLast) ? x * 0.22 : x
    }

    private func pagerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard !currentPageZoomed, !isSettlingPage else { return }
                pagerDrag = value.translation
            }
            .onEnded { value in
                guard !currentPageZoomed, !isSettlingPage else { return }
                let x = value.translation.width
                let y = value.translation.height
                let predictedX = value.predictedEndTranslation.width

                if y > 105, y > abs(x) * 1.15 {
                    dismiss()
                    return
                }

                guard abs(x) > abs(y) * 0.82 else {
                    settleBackToCenter()
                    return
                }

                let shouldPage = abs(x) > width * 0.24
                    || (abs(x) > width * 0.08 && abs(predictedX) > width * 0.52)
                guard shouldPage else {
                    settleBackToCenter()
                    return
                }

                if x < 0, selectedIndex < matches.count - 1 {
                    settlePage(to: selectedIndex + 1, terminalOffset: -width)
                } else if x > 0, selectedIndex > 0 {
                    settlePage(to: selectedIndex - 1, terminalOffset: width)
                } else {
                    settleBackToCenter()
                }
            }
    }

    private func settleBackToCenter() {
        withAnimation(.interactiveSpring(response: 0.46, dampingFraction: 0.90)) {
            pagerDrag = .zero
        }
    }

    private func settlePage(to newIndex: Int, terminalOffset: CGFloat) {
        guard matches.indices.contains(newIndex) else {
            settleBackToCenter()
            return
        }

        isSettlingPage = true
        let settleDuration = 0.52

        withAnimation(.easeInOut(duration: settleDuration)) {
            pagerDrag = CGSize(width: terminalOffset, height: 0)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDuration) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedIndex = newIndex
                pagerDrag = .zero
            }
            currentPageZoomed = false
            isSettlingPage = false
        }
    }

    private func toggleFavorite() {
        guard let currentMatch else { return }
        let next = !currentFavorite
        favoriteOverrides[currentMatch.id] = next
        onFavoriteChanged(currentMatch, next)
    }

    @MainActor
    private func saveCurrent() async {
        guard let currentMatch else { return }
        actionBusy = true
        statusMessage = nil
        defer { actionBusy = false }
        do {
            let image = try await StorageThumbnailLoader.image(path: currentMatch.thumbnailPath, maxPixelSize: 2560)
            try await PhotoBulkActions.saveToPhotoLibrary([image])
            statusMessage = "Saved to Photos."
        } catch AppError.photoLibraryAccessDenied {
            statusMessage = "Allow Photos access in Settings."
        } catch {
            statusMessage = "Couldn't save this photo."
        }
    }

    @MainActor
    private func shareCurrent() async {
        guard let currentMatch else { return }
        actionBusy = true
        statusMessage = nil
        defer { actionBusy = false }
        do {
            shareImage = try await StorageThumbnailLoader.image(path: currentMatch.thumbnailPath, maxPixelSize: 2560)
            showShareSheet = true
        } catch {
            statusMessage = "Couldn't prepare this photo."
        }
    }

    private func detailAction(_ systemImage: String, accessibility: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? Color.red : Color.white)
        .accessibilityLabel(accessibility)
    }

    private func prefetchAdjacent(to index: Int) async {
        guard matches.indices.contains(index) else { return }
        var paths: [String] = []
        if index + 1 < matches.count, let path = matches[index + 1].thumbnailPath { paths.append(path) }
        if index > 0, let path = matches[index - 1].thumbnailPath { paths.append(path) }
        await StorageThumbnailLoader.prefetch(paths: paths, maxPixelSize: 2048)
    }
}

private struct HorizontalPhotoPage: View {
    let match: PhotoMatch
    let onTap: () -> Void
    let onZoomChanged: (Bool) -> Void
    @StateObject private var loader = StorageThumbnailLoader(maxPixelSize: 2048)

    var body: some View {
        Group {
            if let image = loader.image {
                ZoomablePhotoView(image: image, onZoomChanged: onZoomChanged)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .simultaneousGesture(TapGesture().onEnded(onTap))
            } else if loader.failed {
                ContentUnavailableViewCompat(
                    title: "Photo unavailable",
                    message: "Try the photo again.",
                    systemImage: "exclamationmark.triangle"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .transaction { transaction in
            transaction.animation = nil
        }
        .task(id: match.thumbnailPath) { await loader.load(path: match.thumbnailPath) }
    }
}