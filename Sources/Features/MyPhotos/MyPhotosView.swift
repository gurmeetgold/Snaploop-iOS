import FirebaseStorage
import Photos
import SwiftUI
import UIKit

@MainActor
final class MyPhotosModel: ObservableObject {
    @Published var photos: [PhotoMatch] = []
    @Published var participants: [EventParticipant] = []
    @Published var favoriteIds: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var env: AppEnvironment?
    private var session: AppSession?
    let event: Event

    init(event: Event) { self.event = event }

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        async let photosResult = env.matches.myPhotos(eventId: event.id, userId: userId)
        async let participantsResult = env.events.participants(eventId: event.id)

        do { photos = try await photosResult }
        catch { photos = []; errorMessage = (error as NSError).localizedDescription }
        participants = (try? await participantsResult) ?? []
        favoriteIds = LocalPhotoFavoritesStore.load(userId: userId)
    }

    func ownerLabel(for userId: String) -> String {
        if userId == session?.user?.id {
            if let name = session?.user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
            if let phone = session?.user?.phoneNumber, !phone.isEmpty { return phone }
        }
        if let participant = participants.first(where: { $0.userId == userId }) {
            if let name = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
            if let phone = participant.phoneNumber, !phone.isEmpty { return phone }
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
        Array(repeating: GridItem(.flexible(), spacing: columnCount >= 6 ? 4 : 8), count: columnCount)
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
                            title: filter == .favorites ? "No favorites yet" : "No photos of you yet",
                            message: filter == .favorites
                                ? "Open a photo and tap Favorite to keep it here."
                                : "Sync your camera — and as others sync theirs, your matched photos will show up here.",
                            systemImage: filter == .favorites ? "heart" : "person.crop.square"
                        )
                        .frame(minHeight: 280)
                    } else {
                        LazyVGrid(columns: columns, spacing: columnCount >= 6 ? 4 : 8) {
                            ForEach(filtered) { match in
                                NavigationLink {
                                    PhotoDetailView(
                                        match: match,
                                        ownerLabel: model.ownerLabel(for: match.ownerUserId),
                                        isFavorite: model.isFavorite(match),
                                        onFavoriteChanged: { value in model.setFavorite(value, match: match) },
                                        onNotMe: { Task { await model.markNotMe(match) } }
                                    )
                                } label: {
                                    PhotoCard(match: match, ownerLabel: model.ownerLabel(for: match.ownerUserId), isFavorite: model.isFavorite(match), compact: columnCount >= 6)
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
        ZStack(alignment: .bottom) {
            ThumbnailCell(path: match.thumbnailPath).frame(maxWidth: .infinity, maxHeight: .infinity)
            if !compact {
                LinearGradient(colors: [.clear, .black.opacity(0.58)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 4) {
                    Circle().fill(Theme.brandGradient).frame(width: 16, height: 16)
                    Text(ownerLabel).font(.caption2).bold().foregroundStyle(.white).lineLimit(1)
                    Spacer()
                }
                .padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(compact ? .system(size: 8) : .caption)
                    .foregroundStyle(Theme.pink)
                    .padding(compact ? 3 : 7)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 14, style: .continuous))
        .shadow(color: Theme.ink.opacity(compact ? 0 : 0.06), radius: 8, y: 4)
        .contentShape(Rectangle())
    }
}

@MainActor
final class StorageThumbnailLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false
    private static let cache = NSCache<NSString, UIImage>()

    func load(path: String?) async {
        image = nil; failed = false
        guard let path, !path.isEmpty else { failed = true; return }
        if let cached = Self.cache.object(forKey: path as NSString) { image = cached; return }
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                Storage.storage().reference(withPath: path).getData(maxSize: 8 * 1024 * 1024) { data, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let data else { continuation.resume(throwing: AppError.originalUnavailable); return }
                    continuation.resume(returning: data)
                }
            }
            guard let decoded = UIImage(data: data) else { failed = true; return }
            Self.cache.setObject(decoded, forKey: path as NSString); image = decoded
        } catch { failed = true }
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
    let match: PhotoMatch
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

    init(match: PhotoMatch, ownerLabel: String, isFavorite: Bool, onFavoriteChanged: @escaping (Bool) -> Void, onNotMe: @escaping () -> Void) {
        self.match = match; self.ownerLabel = ownerLabel; self.onFavoriteChanged = onFavoriteChanged; self.onNotMe = onNotMe
        _favorite = State(initialValue: isFavorite)
    }

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    preview.frame(maxHeight: 520)
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
                                Text("Shared by \(ownerLabel)").font(.subheadline.bold())
                                Text(DateFormatting.longDate(match.capturedAt)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label("Preview", systemImage: "photo").font(.caption2.bold()).foregroundStyle(Theme.sunset)
                        }
                    }

                    HStack(spacing: 24) {
                        actionButton("Save", "square.and.arrow.down.fill") { Task { await savePreview() } }
                        actionButton("Share", "square.and.arrow.up.fill") { sharePreview() }
                        actionButton(favorite ? "Favorited" : "Favorite", favorite ? "heart.fill" : "heart") { favorite.toggle(); onFavoriteChanged(favorite) }
                        actionButton("Not Me", "person.crop.circle.badge.xmark", role: .destructive) { confirmNotMe = true }
                    }
                    .disabled(loader.image == nil)

                    if let statusMessage { Text(statusMessage).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                }
                .padding()
            }
        }
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: match.thumbnailPath) { await loader.load(path: match.thumbnailPath) }
        .sheet(isPresented: $showShareSheet) { if let shareImage { ActivityView(items: [shareImage]) } }
        .confirmationDialog("This isn't you?", isPresented: $confirmNotMe, titleVisibility: .visible) {
            Button("Not Me", role: .destructive) { onNotMe(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MyPicsTube will hide this photo from My Photos and record the false match so matching can improve.")
        }
    }

    @ViewBuilder private var preview: some View {
        if let image = loader.image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity) }
        else if loader.failed { ContentUnavailableViewCompat(title: "Preview unavailable", message: "Go back and try again.", systemImage: "exclamationmark.triangle") }
        else { ProgressView().frame(maxWidth: .infinity, minHeight: 280) }
    }

    private func sharePreview() {
        guard let image = loader.image else { statusMessage = "The preview is still loading."; return }
        shareImage = image; showShareSheet = true
    }

    @MainActor private func savePreview() async {
        guard let image = loader.image else { statusMessage = "The preview is still loading."; return }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            statusMessage = "Allow MyPicsTube to add photos in iPhone Settings, then try Save again."; return
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
        } catch { statusMessage = "Couldn't save this preview." }
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
