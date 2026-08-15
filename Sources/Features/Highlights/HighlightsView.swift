import SwiftUI

@MainActor
final class HighlightsModel: ObservableObject {
    @Published var highlights: Highlights?
    @Published var isLoading = false
    private var env: AppEnvironment?
    private var session: AppSession?
    let event: Event
    init(event: Event) { self.event = event }
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    var enabled: Bool { env?.config.current.aiHighlightsEnabled ?? false }

    func load() async {
        guard let env, enabled else { return }
        isLoading = true; defer { isLoading = false }
        let photos = (try? await env.matches.sharedAlbum(eventId: event.id)) ?? []
        // Map PhotoMatch → EventPhoto shape the curator understands.
        let eventPhotos = photos.map { m in
            EventPhoto(eventId: m.eventId, sourceUserId: m.ownerUserId, capturedAt: m.capturedAt,
                       thumbnailPath: m.thumbnailPath, width: 1, height: 1, mediaType: .photo,
                       matchedUserIds: m.activeParticipantIds, createdAt: m.matchedAt,
                       sourceAssetReference: m.assetLocalId)
        }
        let quality = await env.quality.signals(for: eventPhotos.map(\.id))
        highlights = HighlightsCurator().curate(eventId: event.id, photos: eventPhotos, quality: quality)
    }
}

/// AI Highlights — a curated static grid. Purely additive; if the feature flag
/// is off (or there's nothing yet) it degrades to a friendly empty state and
/// never affects the core loop.
struct HighlightsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: HighlightsModel
    init(event: Event) { _model = StateObject(wrappedValue: HighlightsModel(event: event)) }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        Group {
            if !model.enabled {
                ContentUnavailableViewCompat(title: "Highlights are off",
                                             message: "This feature isn't turned on right now.",
                                             systemImage: "sparkles")
            } else if let h = model.highlights, !h.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("Group highlights")
                        grid(h.group)
                        if let mine = h.perParticipant[session.user?.id ?? ""], !mine.isEmpty {
                            sectionHeader("Your highlights")
                            grid(mine)
                        }
                    }
                    .padding(.vertical)
                }
            } else {
                ContentUnavailableViewCompat(title: "No highlights yet",
                                             message: "Once there are more photos, your best moments will appear here.",
                                             systemImage: "sparkles")
            }
        }
        .navigationTitle("Highlights")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session); await model.load() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).padding(.horizontal)
    }
    private func grid(_ ids: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(ids, id: \.self) { _ in ThumbnailCell(path: "highlight") }
        }
        .padding(.horizontal, 3)
    }
}
