import FirebaseStorage
import SwiftUI
import UIKit

@MainActor
final class MyPhotosModel: ObservableObject {
    @Published var photos: [PhotoMatch] = []
    @Published var participants: [EventParticipant] = []
    @Published var isLoading = false

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
        defer { isLoading = false }

        async let photosResult = env.matches.myPhotos(eventId: event.id, userId: userId)
        async let participantsResult = env.events.participants(eventId: event.id)

        photos = (try? await photosResult) ?? []
        participants = (try? await participantsResult) ?? []
    }

    func ownerLabel(for userId: String) -> String {
        if userId == session?.user?.id {
            if let name = session?.user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
            if let phone = session?.user?.phoneNumber, !phone.isEmpty { return phone }
        }

        if let participant = participants.first(where: { $0.userId == userId }) {
            if let name = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
            if let phone = participant.phoneNumber, !phone.isEmpty { return phone }
        }
        return "Trip member"
    }

    /// "Not Me" — records the correction and drops the photo from this feed.
    func markNotMe(_ match: PhotoMatch) async {
        guard let env, let userId = session?.user?.id else { return }
        try? await env.matches.dismissAppearance(matchId: match.id, participantUserId: userId)
        photos.removeAll { $0.id == match.id }
    }
}

enum PhotoFilter: String, CaseIterable, Identifiable {
    case all, best, group, portrait, videos
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .best: return "star"
        case .group: return "person.2"
        case .portrait: return "person.crop.square"
        case .videos: return "play.rectangle"
        }
    }
    var isImplemented: Bool { self == .all || self == .videos }
}

struct MyPhotosView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: MyPhotosModel
    @State private var filter: PhotoFilter = .all

    init(event: Event) {
        _model = StateObject(wrappedValue: MyPhotosModel(event: event))
    }

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var filtered: [PhotoMatch] {
        switch filter {
        case .all: return model.photos
        case .videos: return []
        default: return model.photos
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InsightBanner(value: "\(model.photos.count)", label: "photos of you", systemImage: "sparkles")
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PhotoFilter.allCases) { f in
                            FilterChip(title: f.title, systemImage: f.systemImage, isSelected: filter == f) {
                                filter = f
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                if filtered.isEmpty && !model.isLoading {
                    ContentUnavailableViewCompat(
                        title: filter.isImplemented ? "No photos of you yet" : "\(filter.title) is coming soon",
                        message: filter.isImplemented
                            ? "Tap Sync My Camera — and as others sync theirs, your photos will show up here."
                            : "We're still working on this filter.",
                        systemImage: "person.crop.square"
                    )
                    .frame(minHeight: 280)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(filtered) { match in
                            NavigationLink {
                                PhotoDetailView(
                                    match: match,
                                    ownerLabel: model.ownerLabel(for: match.ownerUserId)
                                ) {
                                    Task { await model.markNotMe(match) }
                                }
                            } label: {
                                PhotoCard(
                                    match: match,
                                    ownerLabel: model.ownerLabel(for: match.ownerUserId)
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("\(model.photos.count) photos of you")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.configure(env: env, session: session)
            await model.reload()
        }
        .refreshable { await model.reload() }
    }
}

struct PhotoCard: View {
    let match: PhotoMatch
    var ownerLabel: String = "Trip member"
    var isFavorite = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ThumbnailCell(path: match.thumbnailPath)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 4) {
                Circle().fill(Theme.violetGradient).frame(width: 16, height: 16)
                Text(ownerLabel)
                    .font(.caption2)
                    .bold()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
            }
            .padding(6)
        }
        .aspectRatio(1, contentMode: .fill)
        .overlay(alignment: .topTrailing) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.caption)
                .foregroundStyle(isFavorite ? Theme.coral : .white)
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private final class StorageThumbnailLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private static let cache = NSCache<NSString, UIImage>()

    func load(path: String?) async {
        guard let path, !path.isEmpty else { return }
        if let cached = Self.cache.object(forKey: path as NSString) {
            image = cached
            return
        }

        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                Storage.storage().reference(withPath: path).getData(maxSize: 5 * 1024 * 1024) { data, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let data else {
                        continuation.resume(throwing: AppError.originalUnavailable)
                        return
                    }
                    continuation.resume(returning: data)
                }
            }

            guard let decoded = UIImage(data: data) else {
                failed = true
                return
            }
            Self.cache.setObject(decoded, forKey: path as NSString)
            image = decoded
        } catch {
            failed = true
        }
    }
}

struct ThumbnailCell: View {
    let path: String?
    @StateObject private var loader = StorageThumbnailLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Theme.violetGradient.opacity(0.25))
                    .overlay {
                        if loader.failed {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .task(id: path) { await loader.load(path: path) }
    }
}

struct PhotoDetailView: View {
    let match: PhotoMatch
    let ownerLabel: String
    let onNotMe: () -> Void

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var requestState: String?

    var body: some View {
        VStack(spacing: 16) {
            ThumbnailCell(path: match.thumbnailPath)
                .frame(maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 4) {
                Text("Taken by \(ownerLabel)")
                    .font(.subheadline)
                Text(DateFormatting.longDate(match.capturedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 28) {
                actionButton("Download", "arrow.down.circle") { Task { await requestDownload() } }
                actionButton("Share", "square.and.arrow.up") { }
                actionButton("Favorite", "heart") { }
                actionButton("Not Me", "person.crop.circle.badge.xmark", role: .destructive) {
                    onNotMe()
                    dismiss()
                }
            }

            if let requestState {
                Text(requestState)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func requestDownload() async {
        guard let userId = session.user?.id else { return }
        let job = try? await env.transfers.requestTransfer(
            eventId: match.eventId,
            photo: match,
            requestingUserId: userId
        )
        requestState = job?.userStatus(sourceName: ownerLabel)
    }

    private func actionButton(
        _ title: String,
        _ icon: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
        }
    }
}
