import SwiftUI

@MainActor
final class MyPhotosModel: ObservableObject {
    @Published var photos: [PhotoMatch] = []
    @Published var isLoading = false

    private var env: AppEnvironment?
    private var session: AppSession?
    let event: Event
    init(event: Event) { self.event = event }
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        isLoading = true; defer { isLoading = false }
        photos = (try? await env.matches.myPhotos(eventId: event.id, userId: userId)) ?? []
    }

    /// "Not Me" — records the correction and drops the photo from this feed.
    func markNotMe(_ match: PhotoMatch) async {
        guard let env, let userId = session?.user?.id else { return }
        try? await env.matches.dismissAppearance(matchId: match.id, participantUserId: userId)
        photos.removeAll { $0.id == match.id }
    }
}

/// Filters for the My Photos / Shared Album grids. Only `.all` and `.videos`
/// are backed by real data in this phase (Phase 3 spec: "All required for MVP;
/// Best/Group/Portrait can be stubbed"); the rest show a friendly "coming soon".
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

/// The personal feed: "[N] photos of you". Grid renders thumbnails only — never
/// streams originals just from scrolling.
struct MyPhotosView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: MyPhotosModel
    @State private var filter: PhotoFilter = .all

    init(event: Event) { _model = StateObject(wrappedValue: MyPhotosModel(event: event)) }

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    private var filtered: [PhotoMatch] {
        switch filter {
        case .all: return model.photos
        case .videos: return []   // no video capture in the MVP match pipeline yet
        default: return model.photos   // stubbed filters show everything for now
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
                        systemImage: "person.crop.square")
                        .frame(minHeight: 280)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(filtered) { match in
                            NavigationLink {
                                PhotoDetailView(match: match) { Task { await model.markNotMe(match) } }
                            } label: {
                                PhotoCard(match: match)
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
        .task { model.configure(env: env, session: session); await model.reload() }
        .refreshable { await model.reload() }
    }
}

/// A grid cell in the photo-card style from the designs: rounded thumbnail,
/// bottom-left avatar + attribution, top-right favorite heart.
struct PhotoCard: View {
    let match: PhotoMatch
    var isFavorite = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ThumbnailCell(path: match.thumbnailPath)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 4) {
                Circle().fill(Theme.violetGradient).frame(width: 16, height: 16)
                Text(match.ownerUserId)
                    .font(.caption2).bold().foregroundStyle(.white)
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

/// Placeholder thumbnail cell. Real image loading (from Storage `thumbnailPath`)
/// is wired with the Firebase layer; the contract — thumbnails only, never
/// originals — is fixed here.
struct ThumbnailCell: View {
    let path: String?
    var body: some View {
        Rectangle()
            .fill(Theme.violetGradient.opacity(0.25))
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                Image(systemName: path == nil ? "photo" : "photo.fill")
                    .foregroundStyle(.secondary)
            }
            .clipped()
    }
}

/// Photo detail with attribution + actions.
struct PhotoDetailView: View {
    let match: PhotoMatch
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
                Text("Taken by \(match.ownerUserId)")   // resolved to display name in Firebase layer
                    .font(.subheadline)
                Text(DateFormatting.longDate(match.capturedAt))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 28) {
                actionButton("Download", "arrow.down.circle") { Task { await requestDownload() } }
                actionButton("Share", "square.and.arrow.up") { /* share */ }
                actionButton("Favorite", "heart") { /* favorite */ }
                actionButton("Not Me", "person.crop.circle.badge.xmark", role: .destructive) {
                    onNotMe(); dismiss()
                }
            }
            if let requestState { Text(requestState).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding()
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func requestDownload() async {
        guard let userId = session.user?.id else { return }
        let job = try? await env.transfers.requestTransfer(
            eventId: match.eventId, photo: match, requestingUserId: userId)
        requestState = job?.userStatus(sourceName: match.ownerUserId)
    }

    private func actionButton(_ title: String, _ icon: String, role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
        }
    }
}
