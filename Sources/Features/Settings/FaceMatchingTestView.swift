import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class FaceMatchingTestModel: ObservableObject {
    struct Result {
        let passes: Bool
        let facesFound: Int
    }

    @Published var selectedItem: PhotosPickerItem?
    @Published var previewData: Data?
    @Published var isRunning = false
    @Published var result: Result?
    @Published var errorMessage: String?

    func loadAndTest(env: AppEnvironment, session: AppSession) async {
        guard let selectedItem else { return }
        guard let profile = session.faceProfile,
              profile.version == FaceModelPolicy.currentVersion else {
            errorMessage = "Update Face Setup first."
            return
        }

        isRunning = true
        errorMessage = nil
        result = nil
        defer { isRunning = false }

        do {
            guard let data = try await selectedItem.loadTransferable(type: Data.self) else {
                throw AppError.faceEmbeddingFailed
            }
            previewData = data

            let faces = try await env.faceDetection.detectFaces(in: data)
            let threshold = env.config.current.matchConfidenceThreshold
            let evaluations = faces.compactMap { face -> FaceTemplateMatchEvaluation? in
                let similarities = profile.effectiveEmbeddings.compactMap {
                    face.embedding.cosineSimilarity(to: $0)
                }
                return FaceTemplateMatchPolicy.evaluate(
                    similarities: similarities,
                    threshold: threshold
                )
            }
            let evaluation = evaluations.max { $0.decisionScore < $1.decisionScore }
            result = Result(
                passes: evaluation?.isAccepted == true,
                facesFound: faces.count
            )
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}

struct FaceMatchingTestView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = FaceMatchingTestModel()
    @State private var faceReferenceData: Data?

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    referenceAvatar

                    Text("Test My Face Setup")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)

                    Text("Choose a clear photo of yourself. SnapLoop will check whether your current Face Setup recognizes you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let data = model.previewData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: Theme.ink.opacity(0.08), radius: 12, y: 6)
                    }

                    PhotosPicker(selection: $model.selectedItem, matching: .images, photoLibrary: .shared()) {
                        Label("Choose a Photo", systemImage: "photo.badge.magnifyingglass")
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())
                    .onChange(of: model.selectedItem) { _, _ in
                        Task { await model.loadAndTest(env: env, session: session) }
                    }

                    if model.isRunning {
                        PremiumCard {
                            HStack(spacing: 12) {
                                ProgressView().tint(Theme.sunset)
                                Text("Checking your Face Setup…")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }

                    if let result = model.result {
                        resultCard(result)
                    }

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(22)
            }
        }
        .navigationTitle("Face Test")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadFaceReference() }
        .onChange(of: session.hasFaceProfile) { _, _ in loadFaceReference() }
    }

    @ViewBuilder
    private var referenceAvatar: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                if let data = faceReferenceData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 88, height: 88)
                        .clipShape(Circle())
                        .clipped()
                } else {
                    Circle()
                        .fill(Theme.softWash)
                        .frame(width: 88, height: 88)
                        .overlay {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 50))
                                .foregroundStyle(Theme.violet.opacity(0.70))
                        }
                }

                ZStack {
                    Circle().fill(.white)
                    Image(systemName: "checkmark.viewfinder")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.violet)
                }
                .frame(width: 30, height: 30)
                .shadow(color: Theme.ink.opacity(0.08), radius: 4, y: 2)
            }
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: Theme.ink.opacity(0.10), radius: 10, y: 5)

            Text("Your Face Setup")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resultCard(_ result: FaceMatchingTestModel.Result) -> some View {
        PremiumCard {
            VStack(spacing: 10) {
                Image(systemName: result.passes ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(result.passes ? .green : Theme.amber)

                Text(result.passes ? "Face Setup is working" : "No confident match")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)

                Text(result.passes
                     ? "SnapLoop confidently recognized you in this photo."
                     : (result.facesFound == 0
                        ? "No clear face was found. Try a sharper, front-facing photo."
                        : "Try another clear photo of yourself. If this keeps happening, update Face Setup with a new Selfie Scan."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func loadFaceReference() {
        guard let userId = session.user?.id else {
            faceReferenceData = nil
            return
        }
        faceReferenceData = LocalFaceReferenceStore.load(userId: userId)
    }
}
