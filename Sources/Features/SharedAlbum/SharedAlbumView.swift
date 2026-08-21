import SwiftUI

@MainActor
final class SharedAlbumModel: ObservableObject {
    @Published var photos: [PhotoMatch] = []
    @Published var participants: [EventParticipant] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var env: AppEnvironment?
    private var reloadGeneration = 0
    let event: Event

    init(event: Event) { self.event = event }
    func configure(env: AppEnvironment) { self.env = env }

    func reload() async {
        guard let env else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        errorMessage = nil

        async let photosResult = env.matches.sharedAlbum(eventId: event.id)
        async let participantsResult = env.events.participants(eventId: event.id)

        var loadedPhotos: [PhotoMatch] = []
        var loadedParticipants: [EventParticipant] = []
        var firstError: Error?

        do { loadedPhotos = try await photosResult }
        catch { firstError = error }

        do { loadedParticipants = try await participantsResult }
        catch { if firstError == nil { firstError = error } }

        guard generation == reloadGeneration else { return }
        photos = loadedPhotos
        participants = loadedParticipants
        errorMessage = firstError.map { ($0 as NSError).localizedDescription }
        isLoading = false
    }

    func ownerLabel(for userId: String) -> String {
        guard let participant = participants.first(where: { $0.userId == userId }) else { return "Event member" }
        if let name = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return "Event member"
    }

    var contributorCount: Int { Set(photos.map(\.ownerUserId)).count }
}

struct SharedAlbumView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model: SharedAlbumModel
    @State private var columnCount = 2

    init(event: Event) { _model = StateObject(wrappedValue: SharedAlbumModel(event: event)) }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: columnCount >= 6 ? 4 : 8, alignment: .top), count: columnCount)
    }

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsCard.padding(.horizontal)

                    Text("Shared Album is for this event only. It shows all matched previews members shared here — not only photos containing you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)

                    HStack {
                        Label("Shared moments", systemImage: "person.2.fill")
                            .font(.headline).foregroundStyle(Theme.ink)
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
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(.white.opacity(0.9), in: Capsule())
                                .foregroundStyle(Theme.sunset)
                        }
                    }
                    .padding(.horizontal)

                    if let errorMessage = model.errorMessage {
                        Label("Shared photos could not be fully refreshed. \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    if model.photos.isEmpty && !model.isLoading {
                        ContentUnavailableViewCompat(
                            title: model.errorMessage == nil ? "No shared photos yet" : "Shared photos unavailable",
                            message: model.errorMessage == nil
                                ? "Matched previews shared by members in this event will appear here."
                                : "Pull to refresh. If the problem continues, check your connection and event membership.",
                            systemImage: model.errorMessage == nil ? "photo.stack" : "exclamationmark.triangle"
                        )
                        .frame(minHeight: 280)
                    } else {
                        LazyVGrid(columns: columns, spacing: columnCount >= 6 ? 4 : 8) {
                            ForEach(model.photos) { match in
                                PhotoCard(
                                    match: match,
                                    ownerLabel: model.ownerLabel(for: match.ownerUserId),
                                    compact: columnCount >= 6
                                )
                            }
                        }
                        .padding(.horizontal, columnCount >= 6 ? 8 : 16)
                    }
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Shared Album")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env); await model.reload() }
        .refreshable { await model.reload() }
    }

    private var statsCard: some View {
        HStack(spacing: 0) {
            statTile(value: "\(model.photos.count)", label: "Shared in this event", icon: "photo.stack.fill", tint: Theme.sunset)
            Divider().frame(height: 46)
            statTile(value: "\(model.contributorCount)", label: "Contributors", icon: "person.2.fill", tint: Theme.aqua)
        }
        .padding(.vertical, 16)
        .background(Theme.softWash, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.white.opacity(0.65)))
    }

    private func statTile(value: String, label: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(tint.opacity(0.12))
                Image(systemName: icon).foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)
            Text(value).font(.title3.bold()).foregroundStyle(Theme.ink)
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
