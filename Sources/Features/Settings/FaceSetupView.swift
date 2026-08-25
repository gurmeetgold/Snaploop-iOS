import FirebaseFunctions
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class FaceSetupModel: ObservableObject {
    @Published var previewData: Data?
    @Published var templates: [FaceTemplate] = []
    @Published var isBusy = false
    @Published var message: String?
    @Published var didSave = false
    @Published var consentActive = false
    @Published var hasChanges = false
    @Published var differentIdentityDetected = false

    private var env: AppEnvironment?
    private var session: AppSession?
    private var pendingGuidedReferenceData: Data?

    var guidedTemplateCount: Int { templates.filter { $0.pose != .imported }.count }
    var hasUsableEnrollment: Bool { guidedTemplateCount >= 3 }

    func configure(env: AppEnvironment, session: AppSession) async {
        self.env = env
        self.session = session
        pendingGuidedReferenceData = nil
        differentIdentityDetected = false

        guard let userId = session.user?.id else {
            previewData = nil
            templates = []
            consentActive = false
            didSave = false
            hasChanges = false
            return
        }

        previewData = LocalFaceReferenceStore.load(userId: userId, kind: .guided)
        if let profile = session.faceProfile,
           profile.userId == userId,
           profile.version == FaceModelPolicy.currentVersion {
            templates = profile.templates.filter { $0.pose != .imported }
        } else {
            templates = []
        }
        didSave = false
        hasChanges = false
        if let notice = session.consumeFaceSetupNotice() {
            message = notice
        }
        await refreshConsent()
    }

    func refreshConsent() async {
        guard let env, let userId = session?.user?.id else { return }
        do { consentActive = try await env.biometricConsent.load(userId: userId)?.isActive == true }
        catch { consentActive = false }
    }

    func acceptConsent(_ jurisdiction: BiometricJurisdiction) async -> Bool {
        guard let env, let userId = session?.user?.id,
              jurisdiction.isFaceMatchAvailable else { return false }
        message = nil
        do {
            try await env.biometricConsent.save(BiometricConsentRecord(
                userId: userId,
                acceptedAt: env.clock.now(),
                jurisdictionCountry: jurisdiction.countryCode,
                jurisdictionSubdivision: jurisdiction.subdivisionCode,
                ownFaceAttested: true
            ))
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
        differentIdentityDetected = false
        message = "Building your multi-angle face profile…"

        do {
            var newGuidedTemplates: [FaceTemplate] = []

            for frame in frames {
                let embedding = try await env.faceDetection.embeddingForSelfie(frame.jpegData)
                newGuidedTemplates.append(FaceTemplate(
                    embedding: embedding,
                    pose: frame.pose,
                    quality: frame.quality,
                    createdAt: env.clock.now()
                ))
            }

            guard newGuidedTemplates.count >= 3 else { throw AppError.faceEmbeddingFailed }
            let guided = Array(newGuidedTemplates.sorted { $0.quality > $1.quality }.prefix(FaceModelPolicy.targetTemplateCount))

            // Updating Face Setup is allowed only for the same biometric subject.
            // A mismatch leaves the current profile, preview and matched photos
            // untouched and lets the user explicitly choose whether to delete it.
            if let currentProfile = session?.faceProfile,
               session?.hasFaceProfile == true,
               !sameIdentityReplacement(
                    currentProfile: currentProfile,
                    newTemplates: guided,
                    threshold: env.config.current.matchConfidenceThreshold
               ) {
                isBusy = false
                message = nil
                differentIdentityDetected = true
                return
            }

            templates = guided

            let straightReferenceFrame = frames.first(where: { $0.pose == .alternate })
                ?? frames.first(where: { $0.pose == .center })
                ?? frames.max(by: { $0.quality < $1.quality })

            if let straightReferenceFrame {
                let candidates = try? await VisionFaceCropper.candidates(in: straightReferenceFrame.jpegData)
                let straightReferenceData = candidates?.first?.jpegData ?? straightReferenceFrame.jpegData
                pendingGuidedReferenceData = straightReferenceData
                previewData = straightReferenceData
            }

            hasChanges = true
            message = "Saving Face Setup…"
            isBusy = false
            await saveFaceSetup(automatic: true)
        } catch let error as AppError {
            isBusy = false
            message = error.userMessage
        } catch {
            isBusy = false
            message = (error as NSError).localizedDescription
        }
    }

    /// Restores only the private on-device Face Setup picture after an app
    /// reinstall or device migration. The selected photo must first match the
    /// already-enrolled v5 templates using the same precision policy as normal
    /// matching. No cloud face profile, consent record, or Event data changes.
    func restoreLocalPreview(from imageData: Data) async {
        guard let env, let session, let userId = session.user?.id,
              let profile = session.faceProfile,
              profile.userId == userId,
              profile.version == FaceModelPolicy.currentVersion else {
            message = "Face Setup is not available for this account."
            return
        }

        isBusy = true
        didSave = false
        message = "Checking the photo against your Face Setup…"
        defer { isBusy = false }

        do {
            let faces = try await env.faceDetection.detectFaces(in: imageData)
            guard faces.count == 1, let face = faces.first else {
                message = faces.isEmpty
                    ? "No usable face was found. Choose a clear front-facing photo of yourself."
                    : "Choose a photo containing only you to restore the Face Setup picture."
                return
            }

            let similarities = profile.effectiveEmbeddings.compactMap {
                face.embedding.cosineSimilarity(to: $0)
            }
            guard let evaluation = FaceTemplateMatchPolicy.evaluate(
                similarities: similarities,
                threshold: env.config.current.matchConfidenceThreshold
            ), evaluation.isAccepted else {
                message = "That photo did not confidently match your existing Face Setup. Choose a clearer photo or run Selfie Scan."
                return
            }

            let candidates = try await VisionFaceCropper.candidates(in: imageData)
            guard candidates.count == 1, let candidate = candidates.first else {
                message = "Could not create a clean Face Setup picture from that photo. Try another photo."
                return
            }

            try LocalFaceReferenceStore.save(candidate.jpegData, userId: userId, kind: .guided)
            previewData = candidate.jpegData
            message = "Face photo restored on this iPhone. Your saved Face Setup templates were not changed."
        } catch let error as AppError {
            message = error.userMessage
        } catch {
            message = (error as NSError).localizedDescription
        }
    }

    func saveFaceSetup(automatic: Bool = false) async {
        guard let env, let session, var user = session.user,
              consentActive, hasUsableEnrollment else { return }

        if session.hasFaceProfile && !hasChanges {
            didSave = false
            message = "Face Setup is already up to date."
            return
        }

        let wasUpdate = session.hasFaceProfile
        isBusy = true
        message = automatic ? "Saving Face Setup…" : nil
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
            guard let persistedProfile = try await env.faceProfiles.load(userId: user.id) else {
                throw AppError.decoding("Face Setup was saved but could not be reloaded")
            }

            if let pendingGuidedReferenceData {
                try LocalFaceReferenceStore.save(pendingGuidedReferenceData, userId: user.id, kind: .guided)
            }

            user.hasFaceProfile = true
            try await env.users.save(user)
            try await refreshEventFaceProfiles()
            session.setResolvedFaceProfile(persistedProfile, forUserId: user.id)
            session.updateUser(user)
            templates = persistedProfile.templates.filter { $0.pose != .imported }
            previewData = LocalFaceReferenceStore.load(userId: user.id, kind: .guided) ?? previewData
            pendingGuidedReferenceData = nil
            hasChanges = false
            didSave = true
            message = wasUpdate ? "Face Setup updated." : "Face Setup saved."
        } catch let error as AppError {
            if error == .faceIdentityMismatch {
                message = nil
                differentIdentityDetected = true
            } else {
                message = error.userMessage
            }
        } catch {
            let text = (error as NSError).localizedDescription
            if text.localizedCaseInsensitiveContains("does not match your current Face Setup")
                || text.localizedCaseInsensitiveContains("delete the current Face Setup") {
                message = nil
                differentIdentityDetected = true
            } else {
                message = text
            }
        }
    }

    func deleteFaceSetup() async -> Bool {
        guard let env, let session, let userId = session.user?.id else { return false }
        isBusy = true
        message = nil
        defer { isBusy = false }

        do {
            try await env.faceProfiles.delete(userId: userId)
            LocalFaceReferenceStore.delete(userId: userId)
            templates = []
            previewData = nil
            pendingGuidedReferenceData = nil
            hasChanges = false
            didSave = false
            consentActive = false
            differentIdentityDetected = false
            session.requireFaceSetupAfterDeletion()
            return true
        } catch {
            message = (error as NSError).localizedDescription
            return false
        }
    }

    private func sameIdentityReplacement(
        currentProfile: FaceProfile,
        newTemplates: [FaceTemplate],
        threshold: Double
    ) -> Bool {
        let references = currentProfile.effectiveEmbeddings
        guard references.count >= 2 else { return false }

        let accepted = newTemplates.reduce(into: 0) { count, template in
            let similarities = references.compactMap {
                template.embedding.cosineSimilarity(to: $0)
            }
            if let evaluation = FaceTemplateMatchPolicy.evaluate(
                similarities: similarities,
                threshold: threshold
            ), evaluation.isAccepted {
                count += 1
            }
        }
        let required = max(2, Int(ceil(Double(newTemplates.count) * 0.60)))
        return accepted >= required
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
    private enum PendingAction { case selfie }

    var onSaved: (() -> Void)? = nil
    var allowsDeferral = false
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = FaceSetupModel()
    @State private var showSelfieEnrollment = false
    @State private var showConsent = false
    @State private var showDeleteFaceSetup = false
    @State private var pendingAction: PendingAction?
    @State private var restorePreviewItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    BrandMark(size: 66)
                    Text(session.hasFaceProfile ? "Update Your Face" : "Set Up Your Face")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                    Text("Face Setup enables SnapLoop to find photos of you on participating Event members’ phones.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)

                    PremiumCard { preview }
                    PremiumCard { templateStatus }

                    actionButton("Selfie Scan", icon: "viewfinder.circle.fill", gradient: Theme.brandGradient) {
                        startSelfieFlow()
                    }
                    .disabled(model.isBusy)
                    .opacity(model.isBusy ? 0.62 : 1)

                    if session.hasFaceProfile {
                        NavigationLink { FaceMatchingTestView() } label: {
                            Label("Test My Face Setup", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.magenta)
                        .background(Theme.magenta.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                        Button(role: .destructive) { showDeleteFaceSetup = true } label: {
                            Label("Delete Face Setup", systemImage: "trash.fill")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .disabled(model.isBusy)
                    }

                    if let message = model.message {
                        Label(message, systemImage: model.didSave ? "checkmark.circle.fill" : "info.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(model.didSave ? .green : .secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    if allowsDeferral && !session.hasFaceProfile {
                        Button {
                            session.deferFaceSetup()
                            dismiss()
                        } label: {
                            Label("Skip for now", systemImage: "clock.arrow.circlepath")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 52)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ink)
                        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.violet.opacity(0.18), lineWidth: 1))
                        .disabled(model.isBusy)
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Face Setup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.configure(env: env, session: session) }
        .fullScreenCover(isPresented: $showSelfieEnrollment) {
            GuidedFaceEnrollmentView { frames in
                Task {
                    await model.useGuidedFrames(frames)
                    if model.didSave, onSaved != nil {
                        onSaved?()
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showConsent, onDismiss: resumePendingActionAfterConsent) {
            BiometricConsentView(
                consentActive: false,
                onAccept: { jurisdiction in await model.acceptConsent(jurisdiction) },
                onWithdraw: { false }
            )
        }
        .confirmationDialog(
            "Different Face Detected",
            isPresented: $model.differentIdentityDetected,
            titleVisibility: .visible
        ) {
            Button("Delete Face Setup & Start Over", role: .destructive) {
                Task {
                    if await model.deleteFaceSetup() {
                        pendingAction = .selfie
                        showConsent = true
                    }
                }
            }
            Button("Keep Current Face Setup", role: .cancel) {}
        } message: {
            Text("This scan doesn't appear to be the same person as your current Face Setup. To use a different face, delete the current Face Setup and start again.")
        }
        .confirmationDialog(
            "Delete Face Setup?",
            isPresented: $showDeleteFaceSetup,
            titleVisibility: .visible
        ) {
            Button("Delete Face Setup", role: .destructive) {
                Task {
                    if await model.deleteFaceSetup() {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your Face Setup and face-matched data and turns Face Match off. You'll need fresh consent to set it up again.")
        }
    }

    @MainActor
    private func startSelfieFlow() {
        if model.consentActive {
            showSelfieEnrollment = true
        } else {
            pendingAction = .selfie
            showConsent = true
        }
    }

    @MainActor
    private func resumePendingActionAfterConsent() {
        guard model.consentActive else {
            pendingAction = nil
            return
        }
        let action = pendingAction
        pendingAction = nil
        if action == .selfie { showSelfieEnrollment = true }
    }

    private var preview: some View {
        VStack(spacing: 12) {
            if let data = model.previewData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 190, height: 190)
                    .clipShape(Circle())
                    .clipped()
                    .overlay(Circle().strokeBorder(Theme.brandGradient, lineWidth: 4))
                    .shadow(color: Theme.hotPink.opacity(0.18), radius: 14, y: 7)
                Label("Face Reference Active", systemImage: "checkmark.circle.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("Your selfie reference is stored on this iPhone for this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.softWash)
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(Theme.brandGradient)
                }
                .frame(width: 190, height: 190)
                Text(session.hasFaceProfile
                     ? "Your Face Setup is active. Its private picture is stored only on this iPhone, so it can be removed when SnapLoop is reinstalled. Restore it from a clear photo or run Selfie Scan."
                     : "Your selfie reference will appear here after Face Setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if session.hasFaceProfile {
                    PhotosPicker(selection: $restorePreviewItem, matching: .images, photoLibrary: .shared()) {
                        Label("Restore Face Photo", systemImage: "person.crop.square.filled.and.at.rectangle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.violet)
                    .background(Theme.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(model.isBusy)
                    .onChange(of: restorePreviewItem) { _, item in
                        guard let item else { return }
                        Task {
                            defer { restorePreviewItem = nil }
                            do {
                                guard let data = try await item.loadTransferable(type: Data.self) else {
                                    model.message = "Could not read that photo. Try another one."
                                    return
                                }
                                await model.restoreLocalPreview(from: data)
                            } catch {
                                model.message = (error as NSError).localizedDescription
                            }
                        }
                    }
                    Text("The restored picture stays on this iPhone and is not uploaded to the cloud.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var templateStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Selfie coverage", systemImage: "viewfinder.circle")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(model.guidedTemplateCount)/\(FaceModelPolicy.targetTemplateCount)")
                    .font(.system(.subheadline, design: .rounded).bold())
                    .foregroundStyle(Theme.hotPink)
            }
            ProgressView(value: Double(model.guidedTemplateCount), total: Double(FaceModelPolicy.targetTemplateCount))
                .tint(Theme.hotPink)
            Text(model.guidedTemplateCount >= 3
                 ? "Good pose coverage. These angles improve matching across lighting, expressions and viewpoints."
                 : "Complete the selfie scan for reliable matching.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

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
        .shadow(color: Theme.hotPink.opacity(0.16), radius: 12, y: 5)
    }
}
