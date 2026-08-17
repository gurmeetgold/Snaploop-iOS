import FirebaseFunctions
import SwiftUI
import UIKit

@MainActor
final class FaceSetupModel:
    ObservableObject {

    @Published var previewData: Data?
    @Published var templates: [FaceTemplate] = []
    @Published var faceCandidates: [FaceCropCandidate] = []
    @Published var isBusy = false
    @Published var message: String?
    @Published var didSave = false
    @Published var consentActive = false

    private var env: AppEnvironment?
    private var session: AppSession?

    func configure(
        env: AppEnvironment,
        session: AppSession
    ) async {
        self.env = env
        self.session = session

        if previewData == nil,
           let userId =
            session.user?.id {
            previewData =
                LocalFaceReferenceStore
                    .load(userId: userId)
        }

        if let profile =
            session.faceProfile,
           profile.version
            == FaceModelPolicy.currentVersion {
            templates = profile.templates
        }

        await refreshConsent()
    }

    func refreshConsent() async {
        guard
            let env,
            let userId =
                session?.user?.id
        else {
            return
        }

        do {
            let record =
                try await env.biometricConsent
                    .load(userId: userId)

            consentActive =
                record?.isActive == true
        } catch {
            consentActive = false
        }
    }

    func acceptConsent() async {
        guard
            let env,
            let userId =
                session?.user?.id
        else {
            return
        }

        do {
            let record =
                BiometricConsentRecord(
                    userId: userId,
                    acceptedAt:
                        env.clock.now()
                )

            try await env.biometricConsent
                .save(record)

            consentActive = true
        } catch {
            message =
                (error as NSError)
                    .localizedDescription
        }
    }

    func useGuidedFrames(
        _ frames:
            [GuidedEnrollmentFrame]
    ) async {
        guard let env else { return }

        isBusy = true
        didSave = false
        message =
            "Building a multi-angle face profile…"

        defer {
            isBusy = false
        }

        do {
            var newTemplates:
                [FaceTemplate] = []

            var bestReference:
                (data: Data, quality: Double)?

            for frame in frames {
                let candidates =
                    try await
                    VisionFaceCropper
                        .candidates(
                            in: frame.jpegData
                        )

                guard
                    let candidate =
                        candidates.first
                else {
                    continue
                }

                let embedding =
                    try await
                    env.faceDetection
                        .embeddingForSelfie(
                            candidate.jpegData
                        )

                newTemplates.append(
                    FaceTemplate(
                        embedding: embedding,
                        pose: frame.pose,
                        quality:
                            frame.quality,
                        createdAt:
                            env.clock.now()
                    )
                )

                if bestReference == nil
                    || frame.quality
                        > bestReference!.quality {
                    bestReference = (
                        candidate.jpegData,
                        frame.quality
                    )
                }
            }

            guard
                newTemplates.count >= 3
            else {
                throw AppError
                    .faceEmbeddingFailed
            }

            templates =
                Array(
                    newTemplates
                        .sorted {
                            $0.quality
                                > $1.quality
                        }
                        .prefix(
                            FaceModelPolicy
                                .targetTemplateCount
                        )
                )

            previewData =
                bestReference?.data

            message =
                "Captured \(templates.count) useful face angles. Save Face Setup to use them."

        } catch let error as AppError {
            message = error.userMessage
        } catch {
            message =
                (error as NSError)
                    .localizedDescription
        }
    }

    /// Gallery remains a secondary fallback. A single selected face becomes an
    /// imported template and can be combined with guided enrollment.
    func usePickedImage(
        _ image: UIImage
    ) async {
        guard let env else { return }

        didSave = false
        message = nil
        faceCandidates = []

        guard let data =
            image.jpegData(
                compressionQuality: 0.94
            )
        else {
            message =
                AppError.faceEmbeddingFailed
                    .userMessage
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let candidates =
                try await
                VisionFaceCropper
                    .candidates(in: data)

            guard !candidates.isEmpty
            else {
                throw AppError
                    .noFaceDetectedInSelfie
            }

            if candidates.count == 1 {
                await addCandidateAsTemplate(
                    candidates[0],
                    using: env
                )
            } else {
                faceCandidates =
                    candidates

                message =
                    "We found \(candidates.count) faces. Tap your face."
            }

        } catch let error as AppError {
            message = error.userMessage
        } catch {
            message =
                (error as NSError)
                    .localizedDescription
        }
    }

    func chooseCandidate(
        _ candidate:
            FaceCropCandidate
    ) async {
        guard let env else { return }

        await addCandidateAsTemplate(
            candidate,
            using: env
        )

        faceCandidates = []
    }

    private func addCandidateAsTemplate(
        _ candidate:
            FaceCropCandidate,
        using env: AppEnvironment
    ) async {
        do {
            let embedding =
                try await
                env.faceDetection
                    .embeddingForSelfie(
                        candidate.jpegData
                    )

            let template =
                FaceTemplate(
                    embedding: embedding,
                    pose: .imported,
                    quality: 0.75,
                    createdAt:
                        env.clock.now()
                )

            templates.append(template)

            // Keep a bounded, diverse set.
            if templates.count
                > FaceModelPolicy
                    .targetTemplateCount {
                templates.removeFirst(
                    templates.count
                        - FaceModelPolicy
                            .targetTemplateCount
                )
            }

            previewData =
                candidate.jpegData

            message =
                "Added an alternate face reference."

        } catch let error as AppError {
            message = error.userMessage
        } catch {
            message =
                (error as NSError)
                    .localizedDescription
        }
    }

    func saveFaceSetup() async {
        guard
            let env,
            let session,
            var user = session.user,
            consentActive,
            !templates.isEmpty
        else {
            return
        }

        isBusy = true
        message = nil
        didSave = false

        defer {
            isBusy = false
        }

        do {
            let embeddings =
                templates.map(
                    \.embedding
                )

            guard let centroid =
                FaceEmbedding.centroid(
                    of: embeddings
                )
            else {
                throw AppError
                    .faceEmbeddingFailed
            }

            let profile =
                FaceProfile(
                    userId: user.id,
                    embedding: centroid,
                    templates: templates,
                    version:
                        FaceModelPolicy
                            .currentVersion,
                    updatedAt:
                        env.clock.now()
                )

            try await
                env.faceProfiles
                    .save(profile)

            if let previewData {
                try LocalFaceReferenceStore
                    .save(
                        previewData,
                        userId: user.id
                    )
            }

            user.hasFaceProfile = true

            try await
                env.users.save(user)

            try await
                refreshEventFaceProfiles()

            session.faceProfile =
                profile
            session.user = user

            didSave = true

            message =
                FaceModelPolicy
                    .usesDevelopmentDescriptor
                ? "Multi-angle Face Setup saved. Development matching is ready for testing."
                : "Face Setup saved."

        } catch let error as AppError {
            message = error.userMessage
        } catch {
            message =
                (error as NSError)
                    .localizedDescription
        }
    }

    private func refreshEventFaceProfiles()
        async throws {
        let functions =
            Functions.functions()

        let _: Any =
            try await
            withCheckedThrowingContinuation {
                (
                    continuation:
                        CheckedContinuation<
                            Any,
                            Error
                        >
                ) in

                functions
                    .httpsCallable(
                        "refreshMyFaceProfile"
                    )
                    .call([:]) {
                        result,
                        error in

                        if let error {
                            continuation
                                .resume(
                                    throwing:
                                        error
                                )
                            return
                        }

                        continuation
                            .resume(
                                returning:
                                    result?.data
                                        as Any
                            )
                    }
            }
    }
}

struct FaceSetupView: View {
    var onSaved: (() -> Void)? = nil

    @EnvironmentObject
    private var env:
        AppEnvironment

    @EnvironmentObject
    private var session:
        AppSession

    @Environment(\.dismiss)
    private var dismiss

    @StateObject
    private var model =
        FaceSetupModel()

    @State private var
        showGuidedEnrollment = false

    @State private var
        showGalleryPicker = false

    @State private var
        showConsent = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(
                    systemName: "faceid"
                )
                .font(.system(size: 54))
                .foregroundStyle(
                    Theme.coralGradient
                )

                Text(
                    session.hasFaceProfile
                        ? "Update Your Face"
                        : "Set Up Your Face"
                )
                .font(.title2)
                .bold()

                Text(
                    "Recommended: use the guided camera scan. SnapLoop automatically keeps several useful angles instead of relying on one selfie."
                )
                .font(.subheadline)
                .foregroundStyle(
                    .secondary
                )
                .multilineTextAlignment(
                    .center
                )

                preview

                templateStatus

                if !model.faceCandidates
                    .isEmpty {
                    candidatePicker
                }

                if !model.consentActive {
                    Button {
                        showConsent = true
                    } label: {
                        Label(
                            "Review Face Match Consent",
                            systemImage:
                                "checkmark.shield"
                        )
                        .frame(
                            maxWidth:
                                .infinity
                        )
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .controlSize(.large)
                }

                Button {
                    if model.consentActive {
                        showGuidedEnrollment =
                            true
                    } else {
                        showConsent = true
                    }
                } label: {
                    Label(
                        "Start Guided Face Scan",
                        systemImage:
                            "viewfinder.circle"
                    )
                    .frame(
                        maxWidth:
                            .infinity
                    )
                }
                .buttonStyle(
                    .borderedProminent
                )
                .tint(Theme.coral)
                .controlSize(.large)

                Button {
                    if model.consentActive {
                        showGalleryPicker =
                            true
                    } else {
                        showConsent = true
                    }
                } label: {
                    Label(
                        "Add Existing Photo",
                        systemImage:
                            "photo.on.rectangle"
                    )
                    .frame(
                        maxWidth:
                            .infinity
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task {
                        await model
                            .saveFaceSetup()

                        if model.didSave,
                           onSaved != nil {
                            onSaved?()
                            dismiss()
                        }
                    }
                } label: {
                    Group {
                        if model.isBusy {
                            ProgressView()
                        } else {
                            Text(
                                session
                                    .hasFaceProfile
                                ? "Update Face Setup"
                                : "Save Face Setup"
                            )
                        }
                    }
                    .frame(
                        maxWidth:
                            .infinity
                    )
                }
                .buttonStyle(
                    .borderedProminent
                )
                .tint(Theme.coral)
                .controlSize(.large)
                .disabled(
                    !model.consentActive
                    || model.templates
                        .isEmpty
                    || model.isBusy
                )

                if FaceModelPolicy
                    .usesDevelopmentDescriptor {
                    Label(
                        "The enrollment/multi-template architecture is production-oriented, but this Xcode build still uses the temporary Vision descriptor. A licensed commercial identity engine is the final recognition component.",
                        systemImage:
                            "hammer.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        .orange
                    )
                }

                if let message =
                    model.message {
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(
                            .center
                        )
                }
            }
            .padding(24)
        }
        .navigationTitle("Face Setup")
        .navigationBarTitleDisplayMode(
            .inline
        )
        .task {
            await model.configure(
                env: env,
                session: session
            )
        }
        .fullScreenCover(
            isPresented:
                $showGuidedEnrollment
        ) {
            GuidedFaceEnrollmentView {
                frames in

                Task {
                    await model
                        .useGuidedFrames(
                            frames
                        )
                }
            }
        }
        .sheet(
            isPresented:
                $showConsent
        ) {
            BiometricConsentView {
                Task {
                    await model
                        .acceptConsent()
                }
            }
        }
        .sheet(
            isPresented:
                $showGalleryPicker
        ) {
            ProfileImagePicker(
                source: .photoLibrary
            ) { image in
                showGalleryPicker = false

                Task {
                    await model
                        .usePickedImage(
                            image
                        )
                }
            }
            .ignoresSafeArea()
        }
    }

    private var preview:
        some View {
        Group {
            if let data =
                model.previewData,
               let image =
                UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: 220,
                        height: 220
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 24
                        )
                    )
                    .clipped()
            } else {
                RoundedRectangle(
                    cornerRadius: 24
                )
                .fill(
                    .thinMaterial
                )
                .frame(
                    width: 220,
                    height: 220
                )
                .overlay {
                    Image(
                        systemName:
                            "person.crop.square"
                    )
                    .font(
                        .system(
                            size: 48
                        )
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }
            }
        }
    }

    private var templateStatus:
        some View {
        VStack(
            alignment: .leading,
            spacing: 8
        ) {
            HStack {
                Text(
                    "Enrollment coverage"
                )
                .font(.headline)

                Spacer()

                Text(
                    "\(model.templates.count)/\(FaceModelPolicy.targetTemplateCount)"
                )
                .font(
                    .system(
                        .subheadline,
                        design:
                            .monospaced
                    )
                )
            }

            ProgressView(
                value:
                    Double(
                        model.templates.count
                    ),
                total:
                    Double(
                        FaceModelPolicy
                            .targetTemplateCount
                    )
            )

            Text(
                model.templates.count >= 3
                    ? "Good pose coverage. More diverse views can improve difficult photos."
                    : "Guided enrollment collects multiple angles for a more fault-tolerant profile."
            )
            .font(.caption)
            .foregroundStyle(
                .secondary
            )
        }
        .padding()
        .background(
            .thinMaterial,
            in:
                RoundedRectangle(
                    cornerRadius: 18
                )
        )
    }

    private var candidatePicker:
        some View {
        VStack(
            alignment: .leading,
            spacing: 10
        ) {
            Text(
                "Which face is you?"
            )
            .font(.headline)

            ScrollView(
                .horizontal,
                showsIndicators: false
            ) {
                HStack(spacing: 12) {
                    ForEach(
                        model.faceCandidates
                    ) {
                        candidate in

                        Button {
                            Task {
                                await model
                                    .chooseCandidate(
                                        candidate
                                    )
                            }
                        } label: {
                            if let image =
                                UIImage(
                                    data:
                                        candidate
                                            .jpegData
                                ) {
                                Image(
                                    uiImage:
                                        image
                                )
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width: 96,
                                    height: 96
                                )
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius:
                                            16
                                    )
                                )
                            }
                        }
                        .buttonStyle(
                            .plain
                        )
                    }
                }
            }
        }
    }
}
