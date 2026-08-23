import FirebaseFunctions
import SwiftUI

@MainActor
final class ProfileNameModel: ObservableObject {
    @Published var name: String = ""
    @Published var isSaving = false
    @Published var errorMessage: String?

    func configure(session: AppSession) {
        if name.isEmpty { name = session.user?.displayName ?? "" }
    }

    func save(session: AppSession) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { errorMessage = "Enter at least 2 characters."; return false }
        guard trimmed.count <= 40 else { errorMessage = "Keep your name to 40 characters or fewer."; return false }
        guard var user = session.user else { errorMessage = "Your account session could not be loaded."; return false }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let functions = Functions.functions()
            let _: Any = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Any, Error>) in
                functions.httpsCallable("updateDisplayName").call(["displayName": trimmed]) { result, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let result else {
                        continuation.resume(throwing: AppError.backend(code: "empty_function_result", message: "The server returned no result."))
                        return
                    }
                    continuation.resume(returning: result.data)
                }
            }
            user.displayName = trimmed
            session.updateUser(user)
            return true
        } catch {
            errorMessage = (error as NSError).localizedDescription
            return false
        }
    }
}

struct ProfileNameView: View {
    var onSaved: (() -> Void)? = nil
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ProfileNameModel()

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    BrandMark(size: 56)
                    Text("What should people call you?")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    Text("You can add a display name now or come back to it later.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        session.deferNameSetup()
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Skip for now")
                            Spacer()
                            Text("You can add it later")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.plain)
                    .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.violet.opacity(0.18), lineWidth: 1))
                    .disabled(model.isSaving)

                    PremiumCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Display name", systemImage: "person.text.rectangle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(Theme.ink)
                            TextField("Your name", text: $model.name)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .padding(14)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 15))
                        }
                    }

                    if let errorMessage = model.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task {
                            if await model.save(session: session) {
                                onSaved?()
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            if model.isSaving { ProgressView().tint(.white) }
                            else { Image(systemName: "checkmark.circle.fill") }
                            Text("Save Name")
                        }
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())
                    .disabled(model.isSaving || model.name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                }
                .padding(22)
            }
        }
        .navigationTitle("Your Name")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(session: session) }
    }
}
