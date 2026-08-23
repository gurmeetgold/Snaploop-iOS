import FirebaseFunctions
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

    private var env: AppEnvironment?
    private var session: AppSession?
    private var pendingGuidedReferenceData: Data?

    var guidedTemplateCount: Int { templates.filter { $0.pose != .imported }.count }
    var hasUsableEnrollment: Bool { guidedTemplateCount >= 3 }

    func configure(env: AppEnvironment, session: AppSession) async {
        self.env = env
        self.session = session
        pendingGuidedReferenceData = nil

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

    /// Builds the multi-angle template set and persists it immediately.
    /// A completed guided scan is the save action; there is no second manual save/update step.
    func useGuidedFrames(_ frames: [GuidedEnrollmentFrame]) async {
        guard let env else { return }
        isBusy = true
        didSave = false
        message = "Building your multi-angle face profile…"

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
            pendingGuidedReferenceData = bestReference?.data
            previewData = bestReference?.data ?? previewData
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

    func saveFaceSetup(automatic: Bool = false) async {
        guard let env, let session, var user = session.user,
              consentActive, hasUsableEnrollment else { return }

        if session.hasFaceProfile && !hasChanges {
            didSave = false
            message = "Face Setup is already up to date."
            return
        }

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

            if let pendingGuidedReferenceData {
                try LocalFaceReferenceStore.save(pendingGuidedReferenceData, userId: user.id, kind: .guided)
            }

            user.hasFaceProfile = true
            try await env.users.save(user)
            try await refreshEventFaceProfiles()
            session.setResolvedFaceProfile(profile, forUserId: user.id)
            session.updateUser(user)
            previewData = LocalFaceReferenceStore.load(userId: user.id, kind: .guided) ?? previewData
            pendingGuidedReferenceData = nil
            hasChanges = false
            didSave = true
            message = automatic ? "Face Setup updated automatically." : "Face Setup saved."
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
    private enum PendingAction { case guided }

    var onSaved: (() -> Void)? = nil
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = FaceSetupModel()
    @State private var showGuidedEnrollment = false
    @State private var showConsent = false
    @State private var pendingAction: PendingAction?

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    BrandMark(size: 66)
                    Text(session.hasFaceProfile ? "Update Your Face" : "Set Up Your Face")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                    Text("Complete one guided selfie scan. SnapLoop captures several angles and saves your Face Setup automatically when the scan finishes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)

                    PremiumCard { preview }
                    PremiumCard { templateStatus }

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
            BiometricConsentView { await model.acceptConsent() }
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
        if action == .guided { showGuidedEnrollment = true }
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
                Text("Your guided selfie reference is stored on this iPhone for this account.")
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
                     ? "Your Face Setup is active for this account, but its local selfie preview is not stored on this iPhone. Redo the guided scan only if you want to refresh it."
                     : "Your guided selfie reference will appear here after Face Setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var templateStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Guided selfie coverage", systemImage: "viewfinder.circle")
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
                 ? "Good pose coverage. These controlled angles improve matching across lighting, expressions and viewpoints."
                 : "Complete the guided scan for reliable matching.")
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
