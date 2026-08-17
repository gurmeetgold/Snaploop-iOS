import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class FaceMatchingTestModel: ObservableObject {
    enum ExpectedIdentity: String, CaseIterable, Identifiable {
        case me = "This is me"
        case notMe = "This is NOT me"
        var id: String { rawValue }
    }

    struct Result {
        let diagnostics: FacePipelineDiagnostics?
        let facesFound: Int
        let bestSimilarity: Double?
        let secondTemplateSimilarity: Double?
        let threshold: Double
        let passes: Bool
        let expected: ExpectedIdentity
        let decisionReason: String
        let engineIdentifier: String
        let embeddingDimension: Int?
    }

    struct HistoryRow: Identifiable {
        let id = UUID()
        let expected: ExpectedIdentity
        let best: Double?
        let passed: Bool
        let faces: Int
    }

    @Published var selectedItem: PhotosPickerItem?
    @Published var previewData: Data?
    @Published var isRunning = false
    @Published var result: Result?
    @Published var errorMessage: String?
    @Published var expected: ExpectedIdentity = .me
    @Published var history: [HistoryRow] = []

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

            let pipeline = env.faceDetection as? PipelineFaceDetectionService
            let diagnostics = try await pipeline?.diagnose(in: data)
            let faces: [DetectedFace]
            if let diagnostics {
                faces = diagnostics.samples.compactMap { sample in
                    guard let embedding = sample.embedding else { return nil }
                    return DetectedFace(embedding: embedding, sizeFraction: sample.sizeFraction)
                }
            } else {
                faces = try await env.faceDetection.detectFaces(in: data)
            }

            var similarities: [Double] = []
            for face in faces {
                for template in profile.effectiveEmbeddings {
                    if let score = face.embedding.cosineSimilarity(to: template) {
                        similarities.append(score)
                    }
                }
            }
            similarities.sort(by: >)
            let best = similarities.first
            let second = similarities.count > 1 ? similarities[1] : nil
            let threshold = env.config.current.matchConfidenceThreshold
            let passes = (best ?? -1) >= threshold

            let reason: String
            if diagnostics?.facesDetected == 0 {
                reason = "Vision did not detect a face. Try the original/high-resolution photo."
            } else if diagnostics?.facesWithUsableLandmarks == 0 {
                reason = "A face was detected, but five-point landmarks were not usable."
            } else if let rejected = diagnostics?.samples.first(where: { $0.embedding == nil })?.rejectionReason,
                      faces.isEmpty {
                reason = "Pre-model rejection: \(rejected)."
            } else if best == nil {
                reason = "No comparable embedding was produced."
            } else if passes {
                reason = "Best identity score is above the evaluation threshold."
            } else {
                reason = "Identity score is below threshold; do not force a match."
            }

            let dimension = faces.first?.embedding.values.count
            let engineIdentifier = diagnostics?.engineIdentifier ?? pipeline?.engineIdentifier ?? "unknown"
            let final = Result(
                diagnostics: diagnostics,
                facesFound: faces.count,
                bestSimilarity: best,
                secondTemplateSimilarity: second,
                threshold: threshold,
                passes: passes,
                expected: expected,
                decisionReason: reason,
                engineIdentifier: engineIdentifier,
                embeddingDimension: dimension
            )
            result = final
            history.insert(HistoryRow(expected: expected, best: best, passed: passes, faces: faces.count), at: 0)
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    func clearHistory() { history.removeAll() }
}

struct FaceMatchingTestView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = FaceMatchingTestModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.viewfinder")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.violetGradient)
                Text("Test My Face Setup").font(.title2).bold()
                Text("Choose a photo, tell SnapLoop whether it really contains you, and record the score. Test both genuine and wrong-person photos before changing the threshold.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                Picker("Expected", selection: $model.expected) {
                    ForEach(FaceMatchingTestModel.ExpectedIdentity.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                if let data = model.previewData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }

                PhotosPicker(selection: $model.selectedItem, matching: .images, photoLibrary: .shared()) {
                    Label("Choose Test Photo", systemImage: "photo.badge.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .onChange(of: model.selectedItem) { _, _ in
                    Task { await model.loadAndTest(env: env, session: session) }
                }

                if model.isRunning { ProgressView("Running v5.1 pipeline…") }
                if let result = model.result { resultCard(result) }
                if !model.history.isEmpty { benchmarkHistory }
                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
        .navigationTitle("Face Test")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func resultCard(_ result: FaceMatchingTestModel.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: result.passes ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.passes ? .green : .orange)
                Text(result.passes ? "Threshold passed" : "No confident match").font(.headline)
                Spacer()
            }
            Group {
                Text("Engine: \(result.engineIdentifier)")
                Text("Model version: \(FaceModelPolicy.currentVersion)")
                if let dim = result.embeddingDimension { Text("Embedding: \(dim)-D") }
                Text("Embedded faces: \(result.facesFound)")
                if let d = result.diagnostics {
                    Text("Vision faces: \(d.facesDetected) · usable landmarks: \(d.facesWithUsableLandmarks) · alignment failures: \(d.alignmentFailures)")
                }
                if let best = result.bestSimilarity {
                    Text(String(format: "Best: %.3f · 2nd: %@ · threshold: %.3f", best, result.secondTemplateSimilarity.map { String(format: "%.3f", $0) } ?? "—", result.threshold))
                }
            }
            .font(.system(.caption, design: .monospaced))

            Text(result.decisionReason).font(.caption).foregroundStyle(.secondary)

            if let samples = result.diagnostics?.samples, !samples.isEmpty {
                Divider()
                Text("What AuraFace received").font(.subheadline).bold()
                ForEach(samples) { sample in
                    HStack(alignment: .top, spacing: 10) {
                        if let jpeg = sample.alignedJPEG, let image = UIImage(data: jpeg) {
                            Image(uiImage: image).resizable().interpolation(.high).frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Face \(sample.id + 1)").bold()
                            Text(String(format: "size %.3f · eyes %.1fpx", sample.sizeFraction, sample.interocularPixels))
                            if let q = sample.quality { Text(String(format: "quality %.2f", q)) }
                            Text("yaw \(angle(sample.yawDegrees)) · pitch \(angle(sample.pitchDegrees)) · roll \(angle(sample.rollDegrees))")
                            Text(sample.rejectionReason ?? (sample.embedding == nil ? "not embedded" : "embedded"))
                                .foregroundStyle(sample.embedding == nil ? .orange : .secondary)
                        }.font(.caption2)
                    }
                }
            }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var benchmarkHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This-session benchmark").font(.headline)
                Spacer()
                Button("Clear") { model.clearHistory() }.font(.caption)
            }
            ForEach(model.history.prefix(20)) { row in
                HStack {
                    Text(row.expected == .me ? "GENUINE" : "IMPOSTOR")
                    Spacer()
                    Text(row.best.map { String(format: "%.3f", $0) } ?? "no score")
                    Text(row.passed ? "PASS" : "FAIL")
                }
                .font(.system(.caption, design: .monospaced))
            }
            Text("For a safe threshold, genuine scores should stay well above impostor scores. This history is local to this screen session and contains no photos or embeddings.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func angle(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f°", value)
    }
}
