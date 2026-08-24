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

            // Live builds use LazyFaceDetectionService, so diagnostics must be
            // requested through the diagnostic protocol instead of casting to
            // the concrete pipeline implementation.
            let diagnosticsProvider = env.faceDetection as? FaceDiagnosticsProviding
            let diagnostics = try await diagnosticsProvider?.diagnose(in: data)
            let faces: [DetectedFace]
            if let diagnostics {
                faces = diagnostics.samples.compactMap { sample in
                    guard let embedding = sample.embedding else { return nil }
                    return DetectedFace(embedding: embedding, sizeFraction: sample.sizeFraction)
                }
            } else {
                faces = try await env.faceDetection.detectFaces(in: data)
            }

            // Exercise exactly the same multi-template acceptance policy used
            // by camera matching. The old Face Test flattened every score and
            // used only `best >= threshold`, which made this screen disagree
            // with the production matcher and wasted the five-pose enrollment.
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
            let best = evaluation?.bestTemplate
            let second = evaluation?.secondTemplate
            let passes = evaluation?.isAccepted == true

            let reason: String
            if diagnostics?.facesDetected == 0 {
                reason = "Vision did not detect a face. Try the original/high-resolution photo."
            } else if diagnostics?.facesWithUsableLandmarks == 0 {
                reason = "A face was detected, but five-point landmarks were not usable."
            } else if let rejected = diagnostics?.samples.first(where: { $0.embedding == nil })?.rejectionReason,
                      faces.isEmpty {
                reason = "Pre-model rejection: \(rejected)."
            } else if evaluation == nil {
                reason = "No comparable embedding was produced."
            } else if evaluation?.isStrongSingle == true {
                reason = "Strong single-template identity score passed the precision gate."
            } else if evaluation?.isCorroborated == true {
                let bestFloor = threshold - FaceModelPolicy.corroboratedBestTemplateSlack
                let supportFloor = threshold - FaceModelPolicy.supportingTemplateSlack
                reason = String(
                    format: "Two Face Setup poses corroborate this identity (best floor %.3f · support floor %.3f).",
                    bestFloor,
                    supportFloor
                )
            } else {
                reason = "Identity evidence is too weak or is not corroborated by a second Face Setup pose."
            }

            let dimension = faces.first?.embedding.values.count
            let engineIdentifier = diagnostics?.engineIdentifier ?? env.faceDetection.engineIdentifier
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
        } catch let error as AppError { errorMessage = error.userMessage }
        catch { errorMessage = (error as NSError).localizedDescription }
    }

    func clearHistory() { history.removeAll() }
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
                    Text("Choose a photo, tell SnapLoop whether it really contains you, and record the score. Test both genuine and wrong-person photos before changing the threshold.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    Picker("Expected", selection: $model.expected) {
                        ForEach(FaceMatchingTestModel.ExpectedIdentity.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)

                    if let data = model.previewData, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: Theme.ink.opacity(0.08), radius: 12, y: 6)
                    }

                    PhotosPicker(selection: $model.selectedItem, matching: .images, photoLibrary: .shared()) {
                        Label("Choose Test Photo", systemImage: "photo.badge.magnifyingglass")
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())
                    .onChange(of: model.selectedItem) { _, _ in
                        Task { await model.loadAndTest(env: env, session: session) }
                    }

                    if model.isRunning {
                        PremiumCard {
                            HStack(spacing: 12) {
                                ProgressView().tint(Theme.sunset)
                                Text("Running identity pipeline…").font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                    if let result = model.result { resultCard(result) }
                    if !model.history.isEmpty { benchmarkHistory }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
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

            Text(faceReferenceData == nil ? "Face Setup reference" : "Your Face Setup reference")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func resultCard(_ result: FaceMatchingTestModel.Result) -> some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        Circle().fill((result.passes ? Color.green : Theme.amber).opacity(0.12))
                        Image(systemName: result.passes ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(result.passes ? .green : Theme.amber)
                    }
                    .frame(width: 38, height: 38)
                    Text(result.passes ? "Confident match" : "No confident match").font(.headline)
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
                        Text(String(format: "Best: %.3f · 2nd: %@ · base threshold: %.3f", best, result.secondTemplateSimilarity.map { String(format: "%.3f", $0) } ?? "—", result.threshold))
                    }
                }
                .font(.system(.caption, design: .monospaced))

                Text(result.decisionReason).font(.caption).foregroundStyle(.secondary)

                if let samples = result.diagnostics?.samples, !samples.isEmpty {
                    Divider()
                    Text("What the identity model received").font(.subheadline).bold()
                    ForEach(samples) { sample in
                        HStack(alignment: .top, spacing: 10) {
                            if let jpeg = sample.alignedJPEG, let image = UIImage(data: jpeg) {
                                Image(uiImage: image).resizable().interpolation(.high).frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Face \(sample.id + 1)").bold()
                                Text(String(format: "size %.3f · eyes %.1fpx", sample.sizeFraction, sample.interocularPixels))
                                if let q = sample.quality { Text(String(format: "quality %.2f", q)) }
                                Text("yaw \(angle(sample.yawDegrees)) · pitch \(angle(sample.pitchDegrees)) · roll \(angle(sample.rollDegrees))")
                                Text(sample.rejectionReason ?? (sample.embedding == nil ? "not embedded" : "embedded"))
                                    .foregroundStyle(sample.embedding == nil ? Theme.amber : .secondary)
                            }
                            .font(.caption2)
                        }
                    }
                }
            }
        }
    }

    private var benchmarkHistory: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("This-session benchmark", systemImage: "chart.xyaxis.line")
                        .font(.headline)
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
        }
    }

    private func loadFaceReference() {
        guard let userId = session.user?.id else {
            faceReferenceData = nil
            return
        }
        faceReferenceData = LocalFaceReferenceStore.load(userId: userId)
    }

    private func angle(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f°", value)
    }
}
