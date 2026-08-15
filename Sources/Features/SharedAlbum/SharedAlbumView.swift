import SwiftUI

@MainActor
final class SharedAlbumModel: ObservableObject {
    @Published var photos: [PhotoMatch] = []
    private var env: AppEnvironment?
    let event: Event
    init(event: Event) { self.event = event }
    func configure(env: AppEnvironment) { self.env = env }
    func reload() async {
        guard let env else { return }
        photos = (try? await env.matches.sharedAlbum(eventId: event.id)) ?? []
    }
}

/// The event's shared album — a chronological grid of everyone's matched photos.
struct SharedAlbumView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model: SharedAlbumModel
    init(event: Event) { _model = StateObject(wrappedValue: SharedAlbumModel(event: event)) }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        ScrollView {
            if model.photos.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No shared photos yet",
                    message: "Photos show up here as people sync their cameras.",
                    systemImage: "square.grid.2x2")
                    .frame(minHeight: 320)
            } else {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(model.photos) { ThumbnailCell(path: $0.thumbnailPath) }
                }
                .padding(.horizontal, 3)
            }
        }
        .navigationTitle("Shared Album")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env); await model.reload() }
        .refreshable { await model.reload() }
    }
}
