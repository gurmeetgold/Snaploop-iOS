import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class FaceMatchingTestModel: ObservableObject {

    struct Result {
        let facesFound: Int
        let bestSimilarity: Double?
        let secondTemplateSimilarity: Double?
        let threshold: Double
        let passes: Bool
    }

    @Published var selectedItem: PhotosPickerItem?
    @Published var previewData: Data?
    @Published var isRunning = false
    @Published var result: Result?
    @Published var errorMessage: String?

    func loadAndTest(
        env: AppEnvironment,
        session: AppSession
    ) async {
        guard let selectedItem else {
            return
        }

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
            guard let data = try await selectedItem
                .loadTransferable(type: Data.self) else {
                throw AppError.faceEmbeddingFailed
            }

            previewData = data

            let faces = try await env.faceDetection
                .detectFaces(in: data)

            var allSimilarities: [Double] = []

            for face in faces {
                for template in profile.effectiveEmbeddings {
                    if let similarity = face.embedding
                        .cosineSimilarity(to: template) {
                        allSimilarities.append(similarity)
                    }
                }
            }

            allSimilarities.sort(by: >)

            let best = allSimilarities.first
            let second =
                allSimilarities.count > 1
                ? allSimilarities[1]
                : nil

            let threshold = env.config.current
                .matchConfidenceThreshold

            result = Result(
                facesFound: faces.count,
                bestSimilarity: best,
                secondTemplateSimilarity: second,
                threshold: threshold,
                passes: (best ?? -1) >= threshold
            )

        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = (error as NSError)
                .localizedDescription
        }
    }
}

/// User-visible confidence check.
///
/// This is intentionally a diagnostic before release: choose a gallery photo
/// that contains you (including a group photo) and SnapLoop shows whether the
/// current local descriptor can find you confidently. This is how we validate
/// thresholds against real-world photos instead of guessing.
struct FaceMatchingTestView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession

    @StateObject private var model =
        FaceMatchingTestModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.viewfinder")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.violetGradient)

                Text("Test My Face Setup")
                    .font(.title2)
                    .bold()

                Text(
                    "Choose a photo from your gallery that contains you. A group photo is fine. SnapLoop will scan every face and tell you whether it finds a confident match to your saved Face Setup."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                if let data = model.previewData,
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 18
                            )
                        )
                }

                PhotosPicker(
                    selection: $model.selectedItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label(
                        "Choose Test Photo",
                        systemImage: "photo.badge.magnifyingglass"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .onChange(
                    of: model.selectedItem
                ) { _, _ in
                    Task {
                        await model.loadAndTest(
                            env: env,
                            session: session
                        )
                    }
                }

                if model.isRunning {
                    ProgressView(
                        "Checking every face…"
                    )
                }

                if let result = model.result {
                    resultCard(result)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                if FaceModelPolicy.usesDevelopmentDescriptor {
                    Text(
                        "This test currently measures the DEBUG Vision descriptor. We will repeat the same test suite after installing the dedicated release face model."
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
        .navigationTitle("Face Test")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resultCard(
        _ result: FaceMatchingTestModel.Result
    ) -> some View {
        VStack(spacing: 10) {
            Image(
                systemName:
                    result.passes
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.system(size: 40))
            .foregroundStyle(
                result.passes
                    ? Color.green
                    : Color.orange
            )

            Text(
                result.passes
                    ? "Likely matched to you"
                    : "No confident match yet"
            )
            .font(.headline)

            Text(
                "Faces found: \(result.facesFound)"
            )

            if let similarity =
                result.bestSimilarity {
                Text(
                    String(
                        format:
                            "Best similarity: %.3f · threshold: %.3f",
                        similarity,
                        result.threshold
                    )
                )
                .font(.system(
                    .caption,
                    design: .monospaced
                ))

                if let second =
                    result.secondTemplateSimilarity {
                    Text(
                        String(
                            format:
                                "2nd template: %.3f",
                            second
                        )
                    )
                    .font(.system(
                        .caption2,
                        design: .monospaced
                    ))
                }
            } else {
                Text("No comparable face descriptor.")
                    .font(.caption)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 18
            )
        )
    }
}
