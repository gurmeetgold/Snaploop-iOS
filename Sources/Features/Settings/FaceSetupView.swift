import FirebaseFunctions
import SwiftUI
import UIKit

@MainActor
final class FaceSetupModel: ObservableObject {
    @Published var previewData: Data?
    @Published var templates: [FaceTemplate] = []
    @Published var faceCandidates: [FaceCropCandidate] = []
    @Published var isBusy = false
    @Published var message: String?
    @Published var didSave = false
    @Published var consentActive = false

    private var env: AppEnvironment?
    private var session: AppSession?

    var guidedTemplateCount: Int {
        templates.filter { $0.pose != .imported }.count
    }

    var hasGalleryReference: Bool {
        templates.contains { $0.pose == .imported }
    }

    func configure(env: AppEnvironment, session: AppSession) async {
        self.env = env
        self.session = session

        if let userId = session.user?.id {
            previewData = LocalFaceReferenceStore.load(userId: userId)
        } else {
            previewData = nil
        }

        if let profile = session.faceProfile,
           profile.version == FaceModelPolicy.currentVersion {
            templates = profile.templates
        } else {
            templates = []
        }
        faceCandidates = []
        await refreshConsent()
    }

    func refreshConsent() async {
        guard let env, let userId = session?.user?.id else { return }
        do {
            consentActive = try await env.biometricConsent.load(userId: userId)?.isActive == true
        } catch {
            consentActive = false
        }
    }

    func acceptConsent() async {
        guard let env, let userId = session?.user?.id else { return }
        do {
            let record = BiometricConsentRecord(userId: userId, acceptedAt: env.clock.now())
            try await env.biometricConsent.save(record)
            consentActive = true
        } catch {
            message = (error as NSError).localizedDescription
        }
    }

    func useGuidedFrames(_ frames: [GuidedEnrollmentFrame]) async {
        guard let env else { return }
        isBusy = true
        didSave = false
        message = "Building your v5 multi-angle face profile…"
        defer { isBusy = false }

        do {
            let imported = templates.filter { $0.pose == .imported }.prefix(1)
            var newGuidedTemplates: [FaceTemplate] = []
            var bestReference: (data: Data, quality: Double)?

            for frame in frames {
                let embedding = try await env.faceDetection.embeddingForSelfie(frame.jpegData)
                newGuidedTemplates.append(FaceTemplate(
                    embedding: embedding,
                    pose: frame.pose,
                    quality: frame.quality,
                    createdAt: env.clock.now()
                ))

                if bestReference == nil || frame.quality > bestReference!.quality {
                    let candidates = try? await VisionFaceCropper.candidates(in: frame.jpegData)
                    bestReference = (candidates?.first?.jpegData ?? frame.jpegData, frame.quality)
                }
            }

            guard newGuidedTemplates.count >= 3 else { throw AppError.faceEmbeddingFailed }
            let guided = Array(newGuidedTemplates.sorted { $0.quality > $1.quality }
                .prefix(FaceModelPolicy.targetTemplateCount))
            templates = guided + imported
            previewData = bestReference?.data
            message = "Captured \(guided.count) guided angles. Save Face Setup, then run Face Test."
        } catch let error as AppError {
            message = error.userMessage
        } catch {
            message = (error as NSError).localizedDescription
        }
    }

    /// MVP gallery path: exactly one optional edited image. It is an alternate
    /// reference, not one of the five guided selfie captures.
    func usePickedImage(_ image: UIImage) async {
        guard let env else { return }
        didSave = false
        message = nil
        faceCandidates = []
        guard let data = image.jpegData(compressionQuality: 0.94) else {
            message = AppError.faceEmbeddingFailed.userMessage
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            let candidates = try await VisionFaceCropper.candidates(in: data)
            guard !candidates.isEmpty else { throw AppError.noFaceDetectedInSelfie }
            if candidates.count == 1 {
                await useGalleryCandidate(candidates[0], env: env)
            } else {
                faceCandidates = candidates
                message = "We found \(candidates.count) faces. Tap your face."
            }
        } catch let error as AppError {
            message = error.userMessage
        } catch {
            message = (error as NSError).localizedDescription
        }
    }

    func chooseCandidate(_ candidate: FaceCropCandidate) async {
        guard let env else { return }
        await useGalleryCandidate(candidate, env: env)
        faceCandidates = []
    }

    private func useGalleryCandidate(_ candidate: FaceCropCandidate, env: AppEnvironment) async {
        do {
            let embedding = try await env.faceDetection.embeddingForSelfie(candidate.jpegData)
            // There can never be more than one imported identity reference.
            // Guided templates remain untouched, preventing arbitrary gallery
            // photos from replacing the controlled five-pose enrollment.
            templates.removeAll { $0.pose == .imported }
            templates.append(FaceTemplate(
                embedding: embedding,
                pose: .imported,
                quality: 0.75,
                createdAt: env.clock.now()
            ))
            previewData = candidate.jpegData
            message = "One optional gallery reference is ready. You can edit/replace it before saving."
        } catch let error as AppError {
            message = error.userMessage
        } catch {
            message = (error as NSError).localizedDescription
        }
    }

    func saveFaceSetup() async {
        guard let env, let session, var user = session.user,
              consentActive, !templates.isEmpty else { return }
        isBusy = true
        message = nil
        didSave = false
        defer { isBusy = false }

        do {
            guard let centroid = FaceEmbedding.centroid(of: templates.map(\.embedding)) else {
                throw AppError.faceEmbeddingFailed
            }
            let profile = FaceProfile(
                userId: user.id,
                embedding: centroid,
                templates: templates,
                version: FaceModelPolicy.currentVersion,
                updatedAt: env.clock.now()
            )
            try await env.faceProfiles.save(profile)
            if let previewData {
                try LocalFaceReferenceStore.save(previewData, userId: user.id)
            }
            user.hasFaceProfile = true
            try await env.users.save(user)
            try await refreshEventFaceProfiles()
            session.faceProfile = profile
            session.user = user
            didSave = true
            message = "Face Setup saved. Guided: \(guidedTemplateCount)/\(FaceModelPolicy.targetTemplateCount)\(hasGalleryReference ? ", plus 1 gallery reference" : "")."
        } catch let error as AppError {
            message = error.userMessage
        } catch {
            message = (error as NSError).localizedDescription
        }
    }

    private func refreshEventFaceProfiles() async throws {
        let functions = Functions.functions()
        let _: Any = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            functions.httpsCallable("refreshMyFaceProfile").call([:]) { result, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: result?.data as Any)
            }
        }
    }
}

struct FaceSetupView: View {
    var onSaved: (() -> Void)? = nil
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = FaceSetupModel()
    @State private var showGuidedEnrollment = false
    @State private var showGalleryPicker = false
    @State private var showConsent = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "faceid")
                    .font(.system(size: 52)).foregroundStyle(Theme.coralGradient)
                Text(session.hasFaceProfile ? "Update Your Face" : "Set Up Your Face")
                    .font(.title2).bold()
                Text("Guided Selfie Scan is recommended for MVP accuracy. One gallery photo is optional and never counts as five different enrollment angles.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                preview
                templateStatus

                if !model.faceCandidates.isEmpty { candidatePicker }

                if !model.consentActive {
                    Button { showConsent = true } label: {
                        Label("Review Face Match Consent", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }

                Button {
                    if model.consentActive { showGuidedEnrollment = true } else { showConsent = true }
                } label: {
                    Label("Start Guided Selfie Scan — Recommended", systemImage: "viewfinder.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.coral).controlSize(.large)

                Button {
                    if model.consentActive { showGalleryPicker = true } else { showConsent = true }
                } label: {
                    Label(model.hasGalleryReference ? "Edit / Replace Gallery Photo" : "Add One Gallery Photo", systemImage: "crop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)

                Button {
                    Task {
                        await model.saveFaceSetup()
                        if model.didSave, onSaved != nil { onSaved?(); dismiss() }
                    }
                } label: {
                    Group { if model.isBusy { ProgressView() } else { Text(session.hasFaceProfile ? "Update Face Setup" : "Save Face Setup") } }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.coral).controlSize(.large)
                .disabled(!model.consentActive || model.templates.isEmpty || model.isBusy)

                if session.hasFaceProfile {
                    NavigationLink {
                        FaceMatchingTestView()
                    } label: {
                        Label("Test My Face Setup", systemImage: "checkmark.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }

                if let message = model.message {
                    Text(message).font(.footnote).multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
        .navigationTitle("Face Setup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.configure(env: env, session: session) }
        .fullScreenCover(isPresented: $showGuidedEnrollment) {
            GuidedFaceEnrollmentView { frames in
                Task { await model.useGuidedFrames(frames) }
            }
        }
        .sheet(isPresented: $showConsent) {
            BiometricConsentView { Task { await model.acceptConsent() } }
        }
        .sheet(isPresented: $showGalleryPicker) {
            ProfileImagePicker(source: .photoLibrary) { image in
                showGalleryPicker = false
                Task { await model.usePickedImage(image) }
            }
            .ignoresSafeArea()
        }
    }

    private var preview: some View {
        VStack(spacing: 8) {
            if let data = model.previewData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 24)).clipped()
                Text("Current saved/reference photo")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 24).fill(.thinMaterial)
                    .frame(width: 220, height: 220)
                    .overlay { Image(systemName: "person.crop.square").font(.system(size: 48)).foregroundStyle(.secondary) }
                if session.hasFaceProfile {
                    Text("Your v5 template exists, but this device has no saved preview image yet. Run or update Face Setup once on this phone.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
    }

    private var templateStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Guided selfie coverage").font(.headline)
                Spacer()
                Text("\(model.guidedTemplateCount)/\(FaceModelPolicy.targetTemplateCount)")
                    .font(.system(.subheadline, design: .monospaced))
            }
            ProgressView(
                value: Double(model.guidedTemplateCount),
                total: Double(FaceModelPolicy.targetTemplateCount)
            )
            Text(model.guidedTemplateCount >= 3
                 ? "Good guided pose coverage. The five captures are all taken during one controlled selfie scan."
                 : "Complete the guided scan for the most reliable matching.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            HStack {
                Label("Optional gallery reference", systemImage: "photo")
                    .font(.subheadline)
                Spacer()
                Text(model.hasGalleryReference ? "1 added" : "None")
                    .font(.caption).bold()
                    .foregroundStyle(model.hasGalleryReference ? .green : .secondary)
            }
            Text("MVP allows one gallery face only. If the photo has several people, SnapLoop asks you to choose your face.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var candidatePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which face is you?").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.faceCandidates) { candidate in
                        Button {
                            Task { await model.chooseCandidate(candidate) }
                        } label: {
                            if let image = UIImage(data: candidate.jpegData) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 14)).clipped()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
