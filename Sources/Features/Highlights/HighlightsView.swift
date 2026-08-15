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

/// AI Highlights — a curated collection, presented as category cards (matching
/// the product's visual language) built strictly from what `HighlightsCurator`
/// actually computes: a group reel and a personal reel. We deliberately don't
/// fabricate categories (e.g. "Sunsets", "Funniest Moments") the engine has no
/// signal for — every card here is backed by real selection logic.
/// Purely additive: if the feature flag is off, or there's nothing yet, this
/// degrades to a friendly state and never touches the core sync/match loop.
struct HighlightsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: HighlightsModel
    init(event: Event) { _model = StateObject(wrappedValue: HighlightsModel(event: event)) }

    var body: some View {
        ScrollView {
            Group {
                if !model.enabled {
                    ContentUnavailableViewCompat(title: "Highlights are off",
                                                 message: "This feature isn't turned on right now.",
                                                 systemImage: "sparkles")
                } else if let h = model.highlights, !h.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        categoryCard(title: "Group Highlights", subtitle: "\(h.group.count) memories",
                                    icon: "person.3.fill", gradient: Theme.violetGradient,
                                    destination: HighlightsGridView(title: "Group Highlights", photoIds: h.group))
                        if let mine = h.perParticipant[session.user?.id ?? ""], !mine.isEmpty {
                            categoryCard(title: "Your Highlights", subtitle: "\(mine.count) memories",
                                        icon: "heart.fill", gradient: Theme.coralGradient,
                                        destination: HighlightsGridView(title: "Your Highlights", photoIds: mine))
                        }
                    }
                    .padding()
                } else {
                    ContentUnavailableViewCompat(title: "No highlights yet",
                                                 message: "Once there are more photos, your best moments will appear here.",
                                                 systemImage: "sparkles")
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Highlights")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session); await model.load() }
    }

    private var header: some View {
        InsightBanner(
            value: "\((model.highlights?.group.count ?? 0) + (model.highlights?.perParticipant[session.user?.id ?? ""]?.count ?? 0))",
            label: "memories ready ✨ AI found the best moments", systemImage: "sparkles")
    }

    private func categoryCard<Destination: View>(
        title: String, subtitle: String, icon: String, gradient: LinearGradient, destination: Destination
    ) -> some View {
        NavigationLink { destination } label: {
            GradientTile(title: title, subtitle: subtitle, systemImage: icon, gradient: gradient, height: 140)
        }
        .buttonStyle(.plain)
    }
}

/// The grid behind a highlight category card.
struct HighlightsGridView: View {
    let title: String
    let photoIds: [String]
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(photoIds, id: \.self) { id in
                    ThumbnailCell(path: id)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
