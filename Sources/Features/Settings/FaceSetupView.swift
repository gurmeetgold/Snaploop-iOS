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

    var guidedTemplateCount: Int { templates.filter { $0.pose != .imported }.count }
    var hasGalleryReference: Bool { templates.contains { $0.pose == .imported } }

    func configure(env: AppEnvironment, session: AppSession) async {
        self.env = env
        self.session = session
        previewData = session.user.flatMap { LocalFaceReferenceStore.load(userId: $0.id) }
        if let profile = session.faceProfile, profile.version == FaceModelPolicy.currentVersion {
            templates = profile.templates
        } else {
            templates = []
        }
        faceCandidates = []
        await refreshConsent()
    }

    func refreshConsent() async {
        guard let env, let userId = session?.user?.id else { return }
        do { consentActive = try await env.biometricConsent.load(userId: userId)?.isActive == true }
        catch { consentActive = false }
    }

    func acceptConsent() async {
        guard let env, let userId = session?.user?.id else { return }
        do {
            try await env.biometricConsent.save(BiometricConsentRecord(userId: userId, acceptedAt: env.clock.now()))
            consentActive = true
        } catch { message = (error as NSError).localizedDescription }
    }

    func useGuidedFrames(_ frames: [GuidedEnrollmentFrame]) async {
        guard let env else { return }
        isBusy = true
        didSave = false
        message = "Building your multi-angle face profile…"
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
            let guided = Array(newGuidedTemplates.sorted { $0.quality > $1.quality }.prefix(FaceModelPolicy.targetTemplateCount))
            templates = guided + imported
            previewData = bestReference?.data
            message = "Captured \(guided.count) guided angles. Save Face Setup when you're ready."
        } catch let error as AppError { message = error.userMessage }
        catch { message = (error as NSError).localizedDescription }
    }

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
                message = "We found \(candidates.count) faces. Choose your face below."
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
            templates.removeAll { $0.pose == .imported }
            templates.append(FaceTemplate(
                embedding: embedding,
                pose: .imported,
                quality: 0.75,
                createdAt: env.clock.now()
            ))
            previewData = candidate.jpegData
            message = "Your optional gallery reference is ready."
        } catch let error as AppError { message = error.userMessage }
        catch { message = (error as NSError).localizedDescription }
    }

    func saveFaceSetup() async {
        guard let env, let session, var user = session.user,
              consentActive, !templates.isEmpty else { return }
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
            if let previewData { try LocalFaceReferenceStore.save(previewData, userId: user.id) }
            user.hasFaceProfile = true
            try await env.users.save(user)
            try await refreshEventFaceProfiles()
            session.faceProfile = profile
            session.user = user
            didSave = true
            message = "Face Setup saved. Guided: \(guidedTemplateCount)/\(FaceModelPolicy.targetTemplateCount)\(hasGalleryReference ? ", plus 1 gallery reference" : "")."
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
    var onSaved: (() -> Void)? = nil
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = FaceSetupModel()
    @State private var showGuidedEnrollment = false
    @State private var showGalleryPicker = false
    @State private var showConsent = false

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    BrandMark(size: 58)
                    Text(session.hasFaceProfile ? "Update Your Face" : "Set Up Your Face")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                    Text("A guided selfie scan gives MyPicsRoom the most reliable reference. You can also add one optional gallery photo.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)

                    PremiumCard { preview }
                    PremiumCard { templateStatus }

                    if !model.faceCandidates.isEmpty { PremiumCard { candidatePicker } }

                    if !model.consentActive {
                        actionButton("Review Face Match Consent", icon: "checkmark.shield.fill", gradient: Theme.socialGradient) {
                            showConsent = true
                        }
                    }

                    actionButton("Guided Selfie Scan", icon: "viewfinder.circle.fill", gradient: Theme.brandGradient) {
                        if model.consentActive { showGuidedEnrollment = true } else { showConsent = true }
                    }

                    Button {
                        if model.consentActive { showGalleryPicker = true } else { showConsent = true }
                    } label: {
                        Label(model.hasGalleryReference ? "Edit / Replace Gallery Photo" : "Add One Gallery Photo", systemImage: "photo.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.sunset)
                    .background(Theme.peach.opacity(0.22), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

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
                    .disabled(!model.consentActive || model.templates.isEmpty || model.isBusy)
                    .opacity((!model.consentActive || model.templates.isEmpty || model.isBusy) ? 0.5 : 1)

                    if session.hasFaceProfile {
                        NavigationLink {
                            FaceMatchingTestView()
                        } label: {
                            Label("Test My Face Setup", systemImage: "checkmark.viewfinder")
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
                    Image(systemName: "person.crop.square.filled.and.at.rectangle")
                        .font(.system(size: 48)).foregroundStyle(Theme.violet)
                }
                .frame(width: 190, height: 190)
                if session.hasFaceProfile {
                    Text("Your face profile already exists. This phone does not have a local preview image yet; run Face Setup once here to refresh it.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    Text("Your reference preview will appear here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                 ? "Good pose coverage. The guided scan captures controlled angles of the same person."
                 : "Complete the guided scan for the most reliable matching.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            HStack {
                Label("Optional gallery reference", systemImage: "photo")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.hasGalleryReference ? "1 added" : "None")
                    .font(.caption.bold())
                    .foregroundStyle(model.hasGalleryReference ? .green : .secondary)
            }
            Text("MVP allows one gallery face only. If the photo has several people, MyPicsRoom asks you to choose your face.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var candidatePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Which face is you?", systemImage: "person.crop.rectangle.stack")
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
