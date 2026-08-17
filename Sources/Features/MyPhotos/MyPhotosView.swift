import FirebaseStorage
import Photos
import SwiftUI
import UIKit

@MainActor
final class MyPhotosModel: ObservableObject {
    @Published var photos: [PhotoMatch] = []
    @Published var participants: [EventParticipant] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var env: AppEnvironment?
    private var session: AppSession?
    let event: Event

    init(event: Event) { self.event = event }
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    func reload() async {
        guard let env, let userId = session?.user?.id else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let photosResult = env.matches.myPhotos(eventId: event.id, userId: userId)
            async let participantsResult = env.events.participants(eventId: event.id)
            photos = try await photosResult
            participants = (try? await participantsResult) ?? []
            errorMessage = nil
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
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

    func markNotMe(_ match: PhotoMatch) async -> Bool {
        guard let env, let userId = session?.user?.id else { return false }
        do {
            try await env.matches.dismissAppearance(matchId: match.id, participantUserId: userId)
            photos.removeAll { $0.id == match.id }
            return true
        } catch {
            errorMessage = (error as NSError).localizedDescription
            return false
        }
    }
}

struct MyPhotosView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: MyPhotosModel

    init(event: Event) { _model = StateObject(wrappedValue: MyPhotosModel(event: event)) }

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InsightBanner(value: "\(model.photos.count)", label: "photos of you", systemImage: "sparkles")
                    .padding(.horizontal)

                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }

                if model.photos.isEmpty && !model.isLoading {
                    ContentUnavailableViewCompat(
                        title: "No photos of you yet",
                        message: "Run Sync My Camera. As event members sync their cameras, confident matches appear here.",
                        systemImage: "person.crop.square"
                    )
                    .frame(minHeight: 280)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(model.photos) { match in
                            NavigationLink {
                                PhotoDetailView(match: match, ownerLabel: model.ownerLabel(for: match.ownerUserId)) {
                                    await model.markNotMe(match)
                                }
                            } label: {
                                PhotoCard(match: match, ownerLabel: model.ownerLabel(for: match.ownerUserId))
                                    .frame(height: 116)
                            }
                            .buttonStyle(.plain)
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

struct PhotoCard: View {
    let match: PhotoMatch
    var ownerLabel: String = "Event member"

    var body: some View {
        ZStack(alignment: .bottom) {
            ThumbnailCell(path: match.thumbnailPath)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            HStack {
                Text(ownerLabel).font(.caption2).bold().foregroundStyle(.white).lineLimit(1)
                Spacer()
            }.padding(6)
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
final class StorageThumbnailLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false
    private static let cache = NSCache<NSString, UIImage>()

    func load(path: String?) async {
        guard let path, !path.isEmpty else { failed = true; return }
        if let cached = Self.cache.object(forKey: path as NSString) { image = cached; return }
        do {
            let data = try await Self.data(path: path)
            guard let decoded = UIImage(data: data) else { failed = true; return }
            Self.cache.setObject(decoded, forKey: path as NSString)
            image = decoded
        } catch { failed = true }
    }

    static func data(path: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Storage.storage().reference(withPath: path).getData(maxSize: 8 * 1024 * 1024) { data, error in
                if let error { continuation.resume(throwing: error); return }
                guard let data else { continuation.resume(throwing: AppError.originalUnavailable); return }
                continuation.resume(returning: data)
            }
        }
    }
}

struct ThumbnailCell: View {
    let path: String?
    @StateObject private var loader = StorageThumbnailLoader()

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image = loader.image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Rectangle().fill(Theme.violetGradient.opacity(0.25)).overlay {
                        if loader.failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
                        else { ProgressView() }
                    }
                }
            }
            .clipped()
        }
        .task(id: path) { await loader.load(path: path) }
    }
}

struct PhotoDetailView: View {
    let match: PhotoMatch
    let ownerLabel: String
    let onNotMe: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var statusMessage: String?
    @State private var isSaving = false
    @State private var confirmNotMe = false

    var body: some View {
        VStack(spacing: 16) {
            ThumbnailCell(path: match.thumbnailPath)
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 4) {
                Text("Taken by \(ownerLabel)").font(.subheadline)
                Text(DateFormatting.longDate(match.capturedAt)).font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 48) {
                Button { Task { await saveDisplayedPreview() } } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down").font(.title3)
                        Text(isSaving ? "Saving…" : "Save").font(.caption)
                    }
                }
                .disabled(isSaving)

                Button(role: .destructive) { confirmNotMe = true } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "person.crop.circle.badge.xmark").font(.title3)
                        Text("Not Me").font(.caption)
                    }
                }
            }

            Text("MVP currently displays and saves the matched preview thumbnail. Full-resolution original transfer is intentionally hidden until that workflow is complete.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)

            if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove this from your photos?", isPresented: $confirmNotMe, titleVisibility: .visible) {
            Button("This is Not Me", role: .destructive) {
                Task {
                    if await onNotMe() { dismiss() }
                    else { statusMessage = "Couldn't record the correction. Please try again." }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("SnapLoop will record this as a false match and remove it from your My Photos feed.")
        }
    }

    private func saveDisplayedPreview() async {
        guard let path = match.thumbnailPath, !path.isEmpty else {
            statusMessage = "This preview is not available to save."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let data = try await StorageThumbnailLoader.data(path: path)
            let authorization = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
            }
            guard authorization == .authorized || authorization == .limited else {
                statusMessage = "Allow SnapLoop to add photos in iPhone Settings to save this preview."
                return
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }) { success, error in
                    if let error { continuation.resume(throwing: error) }
                    else if success { continuation.resume(returning: ()) }
                    else { continuation.resume(throwing: AppError.originalUnavailable) }
                }
            }
            statusMessage = "Saved to Photos in preview quality."
        } catch {
            statusMessage = "Couldn't save this preview. Please try again."
        }
    }
}
