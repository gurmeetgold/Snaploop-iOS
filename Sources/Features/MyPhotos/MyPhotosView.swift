import FirebaseFunctions
import FirebaseStorage
import Photos
import SwiftUI
import UIKit

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
    let event: Event

    init(event: Event) { self.event = event }

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        errorMessage = nil

        async let photosResult = env.matches.myPhotos(eventId: event.id, userId: userId)
        async let membersResult = env.events.members(eventId: event.id)

        var loadedPhotos: [PhotoMatch] = []
        var loadedMembers: [EventMember] = []
        var firstError: Error?

        do { loadedPhotos = try await photosResult }
        catch { firstError = error }

        do { loadedMembers = try await membersResult }
        catch { if firstError == nil { firstError = error } }

        guard generation == reloadGeneration, session?.user?.id == userId else { return }
        let sharingEnabled = loadedMembers.first(where: { $0.userId == userId })?.sharingEnabled ?? false
        photos = loadedPhotos.filter { sharingEnabled || $0.ownerUserId != userId }
        members = loadedMembers
        favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
        errorMessage = firstError.map { ($0 as NSError).localizedDescription }
        isLoading = false
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
                                    : "SnapLoop automatically checks eligible live Events for new matched photos. You can also use Sync Camera from an Event at any time.")
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
        .task { model.configure(env: env, session: session); await model.reload() }
        .refreshable { await model.reload() }
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

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 18
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    func load(path: String?) async {
        image = nil; failed = false
        do {
            let decoded = try await Self.image(path: path)
            try Task.checkCancellation()
            image = decoded
        } catch is CancellationError {
            return
        } catch {
            Log.events.error("Matched photo preview load failed: \(String(describing: error), privacy: .public)")
            failed = true
        }
    }

    static func image(path: String?) async throws -> UIImage {
        guard let path, !path.isEmpty else { throw AppError.originalUnavailable }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let decoded = try await fetchImage(path: path)
        store(decoded, path: path)
        return decoded
    }

    static func prefetch(paths: [String]) async {
        for path in Array(paths.prefix(2)) where cache.object(forKey: path as NSString) == nil {
            do {
                let image = try await fetchImage(path: path)
                store(image, path: path)
            } catch {
                continue
            }
        }
    }

    private static func fetchImage(path: String) async throws -> UIImage {
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                Storage.storage().reference(withPath: path).getData(maxSize: 12 * 1024 * 1024) { data, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let data else { continuation.resume(throwing: AppError.originalUnavailable); return }
                    continuation.resume(returning: data)
                }
            }
            guard let decoded = UIImage(data: data) else { throw AppError.originalUnavailable }
            return decoded
        } catch {
            // A matched-photo row has already passed the backend's membership
            // and stable-identity authorization. If the second, client-side
            // Storage read fails, repeat those checks server-side and return
            // only this optimized preview instead of showing a broken tile.
            let data = try await authorizedFallbackData(for: path)
            guard let decoded = UIImage(data: data) else { throw AppError.originalUnavailable }
            return decoded
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

    private static func store(_ image: UIImage, path: String) {
        let decodedCost: Int
        if let cgImage = image.cgImage { decodedCost = cgImage.bytesPerRow * cgImage.height }
        else { decodedCost = 4 * Int(image.size.width * image.size.height) }
        cache.setObject(image, forKey: path as NSString, cost: decodedCost)
    }
}

struct ThumbnailCell: View {
    let path: String?
    @StateObject private var loader = StorageThumbnailLoader()

    var body: some View {
        Group {
            if let image = loader.image { Image(uiImage: image).resizable().scaledToFill() }
            else {
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
            if let image = try? await StorageThumbnailLoader.image(path: match.thumbnailPath) {
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
                selectionAction(allFavorites ? "heart.slash.fill" : "heart.fill", accessibility: allFavorites ? "Remove selected photos from Favorites" : "Favorite selected photos", action: onFavorite)
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
    let isFavorite: (PhotoMatch) -> Bool
    let onFavoriteChanged: (PhotoMatch, Bool) -> Void
    let onNotMe: (PhotoMatch) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMatchID: String
    @State private var chromeVisible = true
    @State private var favoriteOverrides: [String: Bool] = [:]
    @State private var statusMessage: String?
    @State private var shareImage: UIImage?
    @State private var showShareSheet = false
    @State private var confirmNotMe = false
    @State private var actionBusy = false

    init(
        matches: [PhotoMatch],
        initialMatchID: String,
        ownerLabel: @escaping (PhotoMatch) -> String,
        isFavorite: @escaping (PhotoMatch) -> Bool,
        onFavoriteChanged: @escaping (PhotoMatch, Bool) -> Void,
        onNotMe: @escaping (PhotoMatch) -> Void
    ) {
        self.matches = matches
        self.ownerLabel = ownerLabel
        self.isFavorite = isFavorite
        self.onFavoriteChanged = onFavoriteChanged
        self.onNotMe = onNotMe
        _selectedMatchID = State(initialValue: initialMatchID)
    }

    private var currentMatch: PhotoMatch? {
        matches.first(where: { $0.id == selectedMatchID }) ?? matches.first
    }

    private var currentIndex: Int {
        guard let currentMatch, let index = matches.firstIndex(where: { $0.id == currentMatch.id }) else { return 0 }
        return index
    }

    private var currentFavorite: Bool {
        guard let currentMatch else { return false }
        return favoriteOverrides[currentMatch.id] ?? isFavorite(currentMatch)
    }

    var body: some View {
        ZStack {
            (chromeVisible ? Color(uiColor: .systemBackground) : Color.black)
                .ignoresSafeArea()

            TabView(selection: $selectedMatchID) {
                ForEach(matches) { match in
                    HorizontalPhotoPage(match: match, chromeVisible: chromeVisible) {
                        withAnimation(.easeInOut(duration: 0.18)) { chromeVisible.toggle() }
                    }
                    .tag(match.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if chromeVisible, let currentMatch {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(currentIndex + 1) / \(matches.count)")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer()

                    VStack(spacing: 9) {
                        Text("\(ownerLabel(currentMatch)) · \(DateFormatting.longDate(currentMatch.capturedAt))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())

                        HStack(spacing: 28) {
                            detailAction("square.and.arrow.down", accessibility: "Save photo") { Task { await saveCurrent() } }
                            detailAction("square.and.arrow.up", accessibility: "Share photo") { Task { await shareCurrent() } }
                            detailAction(currentFavorite ? "heart.fill" : "heart", accessibility: currentFavorite ? "Remove from Favorites" : "Favorite photo") { toggleFavorite() }
                            detailAction("person.crop.circle.badge.xmark", accessibility: "Not Me", destructive: true) { confirmNotMe = true }
                        }
                        .disabled(actionBusy)

                        if let statusMessage {
                            Text(statusMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
                .transition(.opacity)
            }
        }
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
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
        .task { await prefetchAdjacent(to: selectedMatchID) }
        .onChange(of: selectedMatchID) { _, newValue in
            statusMessage = nil
            Task { await prefetchAdjacent(to: newValue) }
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
            let image = try await StorageThumbnailLoader.image(path: currentMatch.thumbnailPath)
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
            shareImage = try await StorageThumbnailLoader.image(path: currentMatch.thumbnailPath)
            showShareSheet = true
        } catch {
            statusMessage = "Couldn't prepare this photo."
        }
    }

    private func detailAction(_ systemImage: String, accessibility: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 46, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? .red : Theme.ink)
        .accessibilityLabel(accessibility)
    }

    private func prefetchAdjacent(to matchID: String) async {
        guard let index = matches.firstIndex(where: { $0.id == matchID }) else { return }
        var paths: [String] = []
        if index + 1 < matches.count, let path = matches[index + 1].thumbnailPath { paths.append(path) }
        if index > 0, let path = matches[index - 1].thumbnailPath { paths.append(path) }
        await StorageThumbnailLoader.prefetch(paths: paths)
    }
}

private struct HorizontalPhotoPage: View {
    let match: PhotoMatch
    let chromeVisible: Bool
    let onTap: () -> Void
    @StateObject private var loader = StorageThumbnailLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                ZoomablePhotoView(image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .simultaneousGesture(TapGesture().onEnded(onTap))
            } else if loader.failed {
                ContentUnavailableViewCompat(title: "Photo unavailable", message: "Try the photo again.", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(chromeVisible ? Theme.ink : .white)
            } else {
                ProgressView()
                    .tint(chromeVisible ? Theme.ink : .white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.vertical, chromeVisible ? 70 : 0)
        .padding(.horizontal, chromeVisible ? 6 : 0)
        .contentShape(Rectangle())
        .task(id: match.thumbnailPath) { await loader.load(path: match.thumbnailPath) }
    }
}
