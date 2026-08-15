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

/// The personal feed: "[N] photos of you". Grid renders thumbnails only — never
/// streams originals on scroll.
struct MyPhotosView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: MyPhotosModel

    init(event: Event) { _model = StateObject(wrappedValue: MyPhotosModel(event: event)) }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        ScrollView {
            if model.photos.isEmpty && !model.isLoading {
                ContentUnavailableViewCompat(
                    title: "No photos of you yet",
                    message: "Tap Sync My Camera — and as others sync theirs, your photos will show up here.",
                    systemImage: "person.crop.square")
                    .frame(minHeight: 320)
            } else {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(model.photos) { match in
                        NavigationLink {
                            PhotoDetailView(match: match) { Task { await model.markNotMe(match) } }
                        } label: {
                            ThumbnailCell(path: match.thumbnailPath)
                        }
                    }
                }
                .padding(.horizontal, 3)
            }
        }
        .navigationTitle("\(model.photos.count) photos of you")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session); await model.reload() }
        .refreshable { await model.reload() }
    }
}

/// Placeholder thumbnail cell. Real image loading (from Storage `thumbnailPath`)
/// is wired with the Firebase layer; the contract — thumbnails only, never
/// originals — is fixed here.
struct ThumbnailCell: View {
    let path: String?
    var body: some View {
        Rectangle()
            .fill(.quaternary)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            ThumbnailCell(path: match.thumbnailPath)
                .frame(maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 4) {
                Text("Taken by \(match.ownerUserId)")   // resolved to display name in Firebase layer
                    .font(.subheadline)
                Text(DateFormatting.longDate(match.capturedAt))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 28) {
                actionButton("Download", "arrow.down.circle") { /* transfer flow */ }
                actionButton("Share", "square.and.arrow.up") { /* share */ }
                actionButton("Favorite", "heart") { /* favorite */ }
                actionButton("Not Me", "person.crop.circle.badge.xmark", role: .destructive) {
                    onNotMe(); dismiss()
                }
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
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
