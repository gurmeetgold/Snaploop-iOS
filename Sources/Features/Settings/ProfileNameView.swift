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
        guard !isSaving else { return false }
        let trimmed = String(name.prefix(20)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { errorMessage = "Enter at least 2 characters."; return false }
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
    var allowsDeferral = false
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ProfileNameModel()

    private var nameBinding: Binding<String> {
        Binding(
            get: { model.name },
            set: { model.name = String($0.prefix(20)) }
        )
    }

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
                    Text(allowsDeferral
                         ? "You can add a display name now or come back to it later."
                         : "People in your events will see this name.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    PremiumCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Display name", systemImage: "person.text.rectangle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(Theme.ink)
                            TextField("Your name", text: nameBinding)
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
                        guard !model.isSaving else { return }
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MyPicsTubePrimaryButtonStyle())
                    .disabled(model.isSaving || model.name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)

                    if allowsDeferral {
                        Button {
                            session.deferNameSetup()
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
                        .disabled(model.isSaving)
                    }
                }
                .padding(22)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Your Name")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(session: session) }
    }
}
