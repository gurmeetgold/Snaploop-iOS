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
        let engine: String
        let modelVersion: Int
    }

    @Published var selectedItem: PhotosPickerItem?
    @Published var previewData: Data?
    @Published var isRunning = false
    @Published var result: Result?
    @Published var errorMessage: String?

    func loadAndTest(env: AppEnvironment, session: AppSession) async {
        guard let selectedItem else { return }
        guard env.faceDetection.isReadyForMatching else {
            errorMessage = "Face Engine v5 model is not installed in this build."
            return
        }
        guard let profile = session.faceProfile,
              profile.version == FaceModelPolicy.currentVersion else {
            errorMessage = "Redo Face Setup with Face Engine v5 first."
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

            var all: [Double] = []
            for face in faces {
                for template in profile.effectiveEmbeddings {
                    if let score = face.embedding.cosineSimilarity(to: template) {
                        all.append(score)
                    }
                }
            }
            all.sort(by: >)

            let best = all.first
            let second = all.count > 1 ? all[1] : nil
            let threshold = env.config.current.matchConfidenceThreshold
            let supportThreshold = threshold - FaceModelPolicy.supportingTemplateSlack
            let supported = second.map { $0 >= supportThreshold } ?? false
            let strong = (best ?? -1) >= threshold + FaceModelPolicy.strongSingleTemplateBonus
            let passes = (best ?? -1) >= threshold && (supported || strong)

            result = Result(
                facesFound: faces.count,
                bestSimilarity: best,
                secondTemplateSimilarity: second,
                threshold: threshold,
                passes: passes,
                engine: env.faceDetection.engineIdentifier,
                modelVersion: env.faceDetection.modelVersion
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

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.viewfinder")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.violetGradient)

                Text("Test My Face Setup").font(.title2).bold()

                Text("Choose a photo containing you. Group photos are fine. This test uses the v5 identity embedding model, not Apple's generic feature print.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let data = model.previewData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }

                PhotosPicker(selection: $model.selectedItem, matching: .images, photoLibrary: .shared()) {
                    Label("Choose Test Photo", systemImage: "photo.badge.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .onChange(of: model.selectedItem) { _, _ in
                    Task { await model.loadAndTest(env: env, session: session) }
                }

                if model.isRunning { ProgressView("Aligning and checking every face…") }
                if let result = model.result { resultCard(result) }
                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Text("Evaluation build: do not change the threshold from genuine photos alone. We need wrong-person scores too.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .navigationTitle("Face Test")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resultCard(_ result: FaceMatchingTestModel.Result) -> some View {
        VStack(spacing: 9) {
            Image(systemName: result.passes ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(result.passes ? Color.green : Color.orange)

            Text(result.passes ? "Identity evidence passes" : "No confident match yet").font(.headline)
            Text("Faces found: \(result.facesFound)")
            metric("Best", result.bestSimilarity)
            metric("2nd template", result.secondTemplateSimilarity)
            Text(String(format: "Threshold: %.3f", result.threshold)).font(.system(.caption, design: .monospaced))
            Text("Engine: \(result.engine)").font(.system(.caption2, design: .monospaced))
            Text("Model version: \(result.modelVersion)").font(.system(.caption2, design: .monospaced))
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func metric(_ label: String, _ value: Double?) -> some View {
        Group {
            if let value { Text(String(format: "\(label): %.3f", value)) }
            else { Text("\(label): —") }
        }
        .font(.system(.caption, design: .monospaced))
    }
}
