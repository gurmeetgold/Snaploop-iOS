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
                        .padding(.horizontal, columnCount >= 6 ? 8 : 16)
                    }
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("My Photos")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session); await model.reload() }
        .refreshable { await model.reload() }
    }
}

struct PhotoCard: View {
    let match: PhotoMatch
    var ownerLabel: String = "Event member"
    var isFavorite = false
    var compact = false

    var body: some View {
        GeometryReader { geometry in
            ThumbnailCell(path: match.thumbnailPath)
                .frame(width: geometry.size.width, height: geometry.size.width)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(compact ? .system(size: 8) : .caption)
                            .foregroundStyle(Theme.pink)
                            .padding(compact ? 3 : 7)
                    }
                }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 14, style: .continuous))
        .shadow(color: Theme.ink.opacity(compact ? 0 : 0.06), radius: 8, y: 4)
        .contentShape(Rectangle())
        .accessibilityLabel("Photo taken by \(ownerLabel)")
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
        guard let path, !path.isEmpty else { failed = true; return }
        if let cached = Self.cache.object(forKey: path as NSString) { image = cached; return }
        do {
            let decoded = try await Self.fetchImage(path: path)
            try Task.checkCancellation()
            Self.store(decoded, path: path)
            image = decoded
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
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
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            Storage.storage().reference(withPath: path).getData(maxSize: 12 * 1024 * 1024) { data, error in
                if let error { continuation.resume(throwing: error); return }
                guard let data else { continuation.resume(throwing: AppError.originalUnavailable); return }
                continuation.resume(returning: data)
            }
        }
        guard let decoded = UIImage(data: data) else { throw AppError.originalUnavailable }
        return decoded
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

struct PhotoDetailView: View {
    let matches: [PhotoMatch]
    let ownerLabel: (PhotoMatch) -> String
    let isFavorite: (PhotoMatch) -> Bool
    let onFavoriteChanged: (PhotoMatch, Bool) -> Void
    let onNotMe: (PhotoMatch) -> Void

    @State private var selectedMatchID: String

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

    var body: some View {
        ZStack {
            BrandScreenBackground()
            TabView(selection: $selectedMatchID) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                    SinglePhotoPage(
                        match: match,
                        position: index + 1,
                        total: matches.count,
                        ownerLabel: ownerLabel(match),
                        initialFavorite: isFavorite(match),
                        onFavoriteChanged: { onFavoriteChanged(match, $0) },
                        onNotMe: { onNotMe(match) }
                    )
                    .tag(match.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await prefetchAdjacent(to: selectedMatchID) }
        .onChange(of: selectedMatchID) { _, newValue in
            Task { await prefetchAdjacent(to: newValue) }
        }
    }

    private func prefetchAdjacent(to matchID: String) async {
        guard let index = matches.firstIndex(where: { $0.id == matchID }) else { return }
        var paths: [String] = []
        if index + 1 < matches.count, let path = matches[index + 1].thumbnailPath { paths.append(path) }
        if index > 0, let path = matches[index - 1].thumbnailPath { paths.append(path) }
        await StorageThumbnailLoader.prefetch(paths: paths)
    }
}

private struct SinglePhotoPage: View {
    let match: PhotoMatch
    let position: Int
    let total: Int
    let ownerLabel: String
    let onFavoriteChanged: (Bool) -> Void
    let onNotMe: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = StorageThumbnailLoader()
    @State private var favorite: Bool
    @State private var statusMessage: String?
    @State private var showShareSheet = false
    @State private var shareImage: UIImage?
    @State private var confirmNotMe = false

    init(
        match: PhotoMatch,
        position: Int,
        total: Int,
        ownerLabel: String,
        initialFavorite: Bool,
        onFavoriteChanged: @escaping (Bool) -> Void,
        onNotMe: @escaping () -> Void
    ) {
        self.match = match
        self.position = position
        self.total = total
        self.ownerLabel = ownerLabel
        self.onFavoriteChanged = onFavoriteChanged
        self.onNotMe = onNotMe
        _favorite = State(initialValue: initialFavorite)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("\(position) of \(total)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                preview
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Theme.ink.opacity(0.10), radius: 18, y: 8)

                PremiumCard {
                    HStack {
                        ZStack {
                            Circle().fill(Theme.brandGradient)
                            Text(String(ownerLabel.prefix(1)).uppercased()).bold().foregroundStyle(.white)
                        }
                        .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Taken by \(ownerLabel)").font(.subheadline.bold())
                            Text(DateFormatting.longDate(match.capturedAt)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                HStack(spacing: 24) {
                    actionButton("Save", "square.and.arrow.down.fill") { Task { await saveImage() } }
                    actionButton("Share", "square.and.arrow.up.fill") { shareImageAction() }
                    actionButton(favorite ? "Favorited" : "Favorite", favorite ? "heart.fill" : "heart") {
                        favorite.toggle()
                        onFavoriteChanged(favorite)
                    }
                    actionButton("Not Me", "person.crop.circle.badge.xmark", role: .destructive) { confirmNotMe = true }
                }
                .disabled(loader.image == nil)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .task(id: match.thumbnailPath) { await loader.load(path: match.thumbnailPath) }
        .sheet(isPresented: $showShareSheet) { if let shareImage { ActivityView(items: [shareImage]) } }
        .confirmationDialog("This isn't you?", isPresented: $confirmNotMe, titleVisibility: .visible) {
            Button("Not Me", role: .destructive) {
                onNotMe()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SnapLoop will hide this photo and record the false match so matching can improve.")
        }
    }

    @ViewBuilder private var preview: some View {
        if let image = loader.image {
            ZoomablePhotoView(image: image)
                .frame(maxWidth: .infinity)
                .aspectRatio(photoAspectRatio(for: image), contentMode: .fit)
                .frame(minHeight: 360, maxHeight: 680)
        } else if loader.failed {
            ContentUnavailableViewCompat(title: "Photo unavailable", message: "Try the photo again.", systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 360)
        }
    }

    private func photoAspectRatio(for image: UIImage) -> CGFloat {
        guard image.size.height > 0 else { return 1 }
        return max(image.size.width / image.size.height, 0.52)
    }

    private func shareImageAction() {
        guard let image = loader.image else { statusMessage = "The photo is still loading."; return }
        shareImage = image
        showShareSheet = true
    }

    @MainActor private func saveImage() async {
        guard let image = loader.image else { statusMessage = "The photo is still loading."; return }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            statusMessage = "Allow SnapLoop to add photos in iPhone Settings, then try Save again."
            return
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: image) }) { success, error in
                    if let error { continuation.resume(throwing: error) }
                    else if success { continuation.resume(returning: ()) }
                    else { continuation.resume(throwing: AppError.originalUnavailable) }
                }
            }
            statusMessage = "Saved to Photos."
        } catch {
            statusMessage = "Couldn't save this photo."
        }
    }

    private func actionButton(_ title: String, _ icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(role == .destructive ? Color.red.opacity(0.10) : Theme.peach.opacity(0.26))
                    Image(systemName: icon).font(.headline)
                }
                .frame(width: 44, height: 44)
                Text(title).font(.caption2).lineLimit(1)
            }
            .foregroundStyle(role == .destructive ? .red : Theme.ink)
        }
    }
}
