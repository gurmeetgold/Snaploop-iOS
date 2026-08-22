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
    @Published var hasChanges = false

    private var env: AppEnvironment?
    private var session: AppSession?
    private var pendingGuidedReferenceData: Data?
    private var pendingGalleryReferenceData: Data?

    var guidedTemplateCount: Int { templates.filter { $0.pose != .imported }.count }
    var hasGalleryReference: Bool { templates.contains { $0.pose == .imported } }
    var hasUsableEnrollment: Bool {
        #if DEBUG
        return guidedTemplateCount >= 3 || hasGalleryReference
        #else
        return guidedTemplateCount >= 3
        #endif
    }

    func configure(env: AppEnvironment, session: AppSession) async {
        self.env = env
        self.session = session
        pendingGuidedReferenceData = nil
        pendingGalleryReferenceData = nil
        previewData = session.user.flatMap { LocalFaceReferenceStore.load(userId: $0.id, kind: .guided) ?? LocalFaceReferenceStore.load(userId: $0.id) }
        if let profile = session.faceProfile, profile.version == FaceModelPolicy.currentVersion {
            templates = profile.templates
        } else {
            templates = []
        }
        faceCandidates = []
        didSave = false
        hasChanges = false
        await refreshConsent()
    }

    func refreshConsent() async {
        guard let env, let userId = session?.user?.id else { return }
        do { consentActive = try await env.biometricConsent.load(userId: userId)?.isActive == true }
        catch { consentActive = false }
    }

    func acceptConsent() async -> Bool {
        guard let env, let userId = session?.user?.id else { return false }
        message = nil
        do {
            try await env.biometricConsent.save(BiometricConsentRecord(userId: userId, acceptedAt: env.clock.now()))
            consentActive = true
            return true
        } catch {
            consentActive = false
            message = (error as NSError).localizedDescription
            return false
        }
    }

    func useGuidedFrames(_ frames: [GuidedEnrollmentFrame]) async {
        guard let env else { return }
        isBusy = true
        didSave = false
        message = "Building your multi-angle face profile…"
        defer { isBusy = false }

        do {
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
            let guided = Array(newGuidedTemplates.sorted { $0.quality > $1.quality }.prefix(FaceModelPolicy.targetTemplateCount))
            templates = guided
            pendingGalleryReferenceData = nil
            pendingGuidedReferenceData = bestReference?.data
            previewData = bestReference?.data ?? previewData
            hasChanges = true
            message = "Captured \(guided.count) guided angles. Save Face Setup when you're ready."
        } catch let error as AppError { message = error.userMessage }
        catch { message = (error as NSError).localizedDescription }
    }

    #if DEBUG
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
                message = "We found \(candidates.count) faces. Choose the test identity below."
            }
        } catch let error as AppError { message = error.userMessage }
        catch { message = (error as NSError).localizedDescription }
    }

    func chooseCandidate(_ candidate: FaceCropCandidate) async {
        guard let env else { return }
        await useGalleryCandidate(candidate, env: env)
        faceCandidates = []
    }

    private func useGalleryCandidate(_ candidate: FaceCropCandidate, env: AppEnvironment) async {
        do {
            let embedding = try await env.faceDetection.embeddingForSelfie(candidate.jpegData)
            templates = [FaceTemplate(
                embedding: embedding,
                pose: .imported,
                quality: 0.75,
                createdAt: env.clock.now()
            )]
            pendingGalleryReferenceData = candidate.jpegData
            previewData = candidate.jpegData
            hasChanges = true
            message = "Debug test identity is ready."
        } catch let error as AppError { message = error.userMessage }
        catch { message = (error as NSError).localizedDescription }
    }
    #endif

    func saveFaceSetup() async {
        guard let env, let session, var user = session.user,
              consentActive, hasUsableEnrollment else { return }

        if session.hasFaceProfile && !hasChanges {
            didSave = false
            message = "No changes to save."
            return
        }

        isBusy = true
        message = nil
        didSave = false
        defer { isBusy = false }

        do {
            guard let centroid = FaceEmbedding.centroid(of: templates.map(\.embedding)) else { throw AppError.faceEmbeddingFailed }
            let profile = FaceProfile(
                userId: user.id,
                embedding: centroid,
                templates: templates,
                version: FaceModelPolicy.currentVersion,
                updatedAt: env.clock.now()
            )
            try await env.faceProfiles.save(profile)

            if let pendingGuidedReferenceData {
                try LocalFaceReferenceStore.save(pendingGuidedReferenceData, userId: user.id, kind: .guided)
            }
            #if DEBUG
            if let pendingGalleryReferenceData {
                try LocalFaceReferenceStore.save(pendingGalleryReferenceData, userId: user.id, kind: .gallery)
            }
            #endif

            user.hasFaceProfile = true
            try await env.users.save(user)
            try await refreshEventFaceProfiles()
            session.faceProfile = profile
            session.user = user
            previewData = LocalFaceReferenceStore.load(userId: user.id, kind: .guided) ?? previewData
            pendingGuidedReferenceData = nil
            pendingGalleryReferenceData = nil
            hasChanges = false
            didSave = true
            message = "Face Setup saved."
        } catch let error as AppError { message = error.userMessage }
        catch { message = (error as NSError).localizedDescription }
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
    private enum PendingAction { case guided
        #if DEBUG
        case debugGallery
        #endif
    }

    var onSaved: (() -> Void)? = nil
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = FaceSetupModel()
    @State private var showGuidedEnrollment = false
    @State private var showGalleryPicker = false
    @State private var showConsent = false
    @State private var pendingAction: PendingAction?

    private var saveDisabled: Bool {
        !model.consentActive || !model.hasUsableEnrollment || model.isBusy || (session.hasFaceProfile && !model.hasChanges)
    }

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    BrandMark(size: 58)
                    Text(session.hasFaceProfile ? "Update Your Face" : "Set Up Your Face")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                    Text("Complete one guided selfie scan. SnapLoop captures several angles of your face for more reliable matching.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)

                    PremiumCard { preview }
                    PremiumCard { templateStatus }

                    #if DEBUG
                    if !model.faceCandidates.isEmpty { PremiumCard { candidatePicker } }
                    #endif

                    if !model.consentActive {
                        actionButton("Review Face Match Consent", icon: "checkmark.shield.fill", gradient: Theme.socialGradient) {
                            pendingAction = nil
                            showConsent = true
                        }
                    }

                    actionButton("Guided Selfie Scan", icon: "viewfinder.circle.fill", gradient: Theme.brandGradient) {
                        if model.consentActive {
                            showGuidedEnrollment = true
                        } else {
                            pendingAction = .guided
                            showConsent = true
                        }
                    }

                    #if DEBUG
                    Button {
                        if model.consentActive {
                            showGalleryPicker = true
                        } else {
                            pendingAction = .debugGallery
                            showConsent = true
                        }
                    } label: {
                        Label("Developer Test: Use Gallery Face", systemImage: "hammer.fill")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.violet)
                    .background(Theme.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    #endif

                    Button {
                        Task {
                            await model.saveFaceSetup()
                            if model.didSave, onSaved != nil { onSaved?(); dismiss() }
                        }
                    } label: {
                        HStack {
                            if model.isBusy { ProgressView().tint(.white) }
                            else { Image(systemName: "checkmark.seal.fill") }
                            Text(session.hasFaceProfile ? "Update Face Setup" : "Save Face Setup")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .disabled(saveDisabled)
                    .opacity(saveDisabled ? 0.5 : 1)

                    if session.hasFaceProfile {
                        NavigationLink { FaceMatchingTestView() } label: {
                            Label("Test My Face Setup", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.violet)
                        .background(Theme.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    if let message = model.message {
                        Label(message, systemImage: model.didSave ? "checkmark.circle.fill" : "info.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(model.didSave ? .green : .secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Face Setup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.configure(env: env, session: session) }
        .fullScreenCover(isPresented: $showGuidedEnrollment) {
            GuidedFaceEnrollmentView { frames in Task { await model.useGuidedFrames(frames) } }
        }
        .sheet(isPresented: $showConsent, onDismiss: resumePendingActionAfterConsent) {
            BiometricConsentView { await model.acceptConsent() }
        }
        #if DEBUG
        .sheet(isPresented: $showGalleryPicker) {
            ProfileImagePicker(source: .photoLibrary) { image in
                showGalleryPicker = false
                Task { await model.usePickedImage(image) }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    @MainActor
    private func resumePendingActionAfterConsent() {
        guard model.consentActive else {
            pendingAction = nil
            return
        }
        let action = pendingAction
        pendingAction = nil
        switch action {
        case .guided: showGuidedEnrollment = true
        #if DEBUG
        case .debugGallery: showGalleryPicker = true
        #endif
        case nil: break
        }
    }

    private var preview: some View {
        VStack(spacing: 10) {
            if let data = model.previewData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: 190, height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .clipped()
                    .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white, lineWidth: 3))
                    .shadow(color: Theme.ink.opacity(0.10), radius: 12, y: 6)
                Label("Current face reference", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.softWash)
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 58)).foregroundStyle(Theme.violet.opacity(0.72))
                }
                .frame(width: 190, height: 190)
                Text(session.hasFaceProfile
                     ? "Your Face Setup is active. Redo the guided selfie scan to update it."
                     : "Your face reference will appear here after the guided selfie scan.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var templateStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Guided selfie coverage", systemImage: "viewfinder.circle")
                    .font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(model.guidedTemplateCount)/\(FaceModelPolicy.targetTemplateCount)")
                    .font(.system(.subheadline, design: .rounded).bold())
                    .foregroundStyle(Theme.sunset)
            }
            ProgressView(value: Double(model.guidedTemplateCount), total: Double(FaceModelPolicy.targetTemplateCount))
                .tint(Theme.sunset)
            Text(model.guidedTemplateCount >= 3
                 ? "Good pose coverage. These controlled angles improve matching across lighting, expressions and viewpoints."
                 : "Complete the guided scan for reliable matching.")
                .font(.caption).foregroundStyle(.secondary)

            #if DEBUG
            if model.hasGalleryReference {
                Divider()
                Label("Debug gallery identity active", systemImage: "hammer.fill")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.violet)
            }
            #endif
        }
    }

    #if DEBUG
    private var candidatePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Choose the test identity", systemImage: "person.crop.rectangle.stack")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.faceCandidates) { candidate in
                        Button { Task { await model.chooseCandidate(candidate) } } label: {
                            if let image = UIImage(data: candidate.jpegData) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 18)).clipped()
                                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.sunset.opacity(0.5), lineWidth: 2))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    #endif

    private func actionButton(_ title: String, icon: String, gradient: LinearGradient, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.08), radius: 10, y: 5)
    }
}
