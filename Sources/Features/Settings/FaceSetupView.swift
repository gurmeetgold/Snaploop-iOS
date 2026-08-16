import PhotosUI
import SwiftUI

@MainActor
final class FaceSetupModel: ObservableObject {
    @Published var selectedItem: PhotosPickerItem?
    @Published var previewData: Data?
    @Published var isBusy = false
    @Published var message: String?
    @Published var didSave = false

    private var env: AppEnvironment?
    private var session: AppSession?

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    func loadSelectedPhoto() async {
        guard let selectedItem else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }

        do {
            guard let data = try await selectedItem.loadTransferable(type: Data.self), !data.isEmpty else {
                throw AppError.faceEmbeddingFailed
            }
            previewData = data
        } catch let error as AppError {
            message = error.userMessage
        } catch {
            message = AppError.unknown("\(error)").userMessage
        }
    }

    func saveFaceSetup() async {
        guard let env, let session, var user = session.user, let imageData = previewData else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }

        do {
            let embedding = try await env.faceDetection.embeddingForSelfie(imageData)
            let nextVersion = (session.faceProfile?.version ?? 0) + 1
            let profile = FaceProfile(
                userId: user.id,
                embedding: embedding,
                version: nextVersion,
                updatedAt: env.clock.now()
            )

            try await env.faceProfiles.save(profile)

            user.hasFaceProfile = true
            try await env.users.save(user)

            session.faceProfile = profile
            session.user = user
            didSave = true
            message = "Face setup saved."
        } catch let error as AppError {
            message = error.userMessage
        } catch {
            message = AppError.unknown("\(error)").userMessage
        }
    }
}

/// Face-profile setup UI.
///
/// For Simulator testing, choose a selfie from the Photos library. The source
/// image remains local; only the embedding returned by FaceDetectionService is
/// persisted through FaceProfileStore.
struct FaceSetupView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = FaceSetupModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "faceid")
                    .font(.system(size: 54))
                    .foregroundStyle(Theme.coralGradient)

                Text(session.hasFaceProfile ? "Update Your Face" : "Set Up Your Face")
                    .font(.title2).bold()

                Text("Choose one clear selfie with only you in the frame. SnapLoop uses it to create your private face profile on-device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let data = model.previewData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                } else {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.thinMaterial)
                        .frame(width: 220, height: 220)
                        .overlay {
                            Image(systemName: "person.crop.square")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                        }
                }

                PhotosPicker(
                    selection: $model.selectedItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label(model.previewData == nil ? "Choose Selfie" : "Choose Different Selfie",
                          systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .onChange(of: model.selectedItem) { _, _ in
                    Task { await model.loadSelectedPhoto() }
                }

                Button {
                    Task { await model.saveFaceSetup() }
                } label: {
                    Group {
                        if model.isBusy {
                            ProgressView()
                        } else {
                            Text(session.hasFaceProfile ? "Update Face Setup" : "Save Face Setup")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.coral)
                .controlSize(.large)
                .disabled(model.previewData == nil || model.isBusy)

                if let message = model.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(model.didSave ? Color.secondary : Color.red)
                        .multilineTextAlignment(.center)
                }

                if model.didSave {
                    Button("Done") { dismiss() }
                        .font(.headline)
                }
            }
            .padding(24)
        }
        .navigationTitle("Face Setup")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session) }
    }
}
