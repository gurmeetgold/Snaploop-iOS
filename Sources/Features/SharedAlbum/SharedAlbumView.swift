import SwiftUI

@MainActor
final class SharedAlbumModel: ObservableObject {
    @Published var photos: [PhotoMatch] = []
    @Published var participants: [EventParticipant] = []

    private var env: AppEnvironment?
    let event: Event

    init(event: Event) { self.event = event }
    func configure(env: AppEnvironment) { self.env = env }

    func reload() async {
        guard let env else { return }
        async let photosResult = env.matches.sharedAlbum(eventId: event.id)
        async let participantsResult = env.events.participants(eventId: event.id)
        photos = (try? await photosResult) ?? []
        participants = (try? await participantsResult) ?? []
    }

    func ownerLabel(for userId: String) -> String {
        guard let participant = participants.first(where: { $0.userId == userId }) else { return "Event member" }
        if let name = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let phone = participant.phoneNumber, !phone.isEmpty { return phone }
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

                    if model.photos.isEmpty {
                        ContentUnavailableViewCompat(
                            title: "No shared photos yet",
                            message: "Matched previews shared by members in this event will appear here.",
                            systemImage: "photo.stack"
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
