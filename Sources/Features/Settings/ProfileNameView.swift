import FirebaseFunctions
import SwiftUI

@MainActor
final class ProfileNameModel: ObservableObject {
    @Published var name: String = ""
    @Published var isSaving = false
    @Published var errorMessage: String?

    func configure(session: AppSession) {
        if name.isEmpty {
            name = session.user?.displayName ?? ""
        }
    }

    func save(session: AppSession) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= 2 else {
            errorMessage = "Enter at least 2 characters."
            return false
        }

        guard trimmed.count <= 40 else {
            errorMessage = "Keep your name to 40 characters or fewer."
            return false
        }

        guard var user = session.user else {
            errorMessage = "Your account session could not be loaded."
            return false
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let functions = Functions.functions()
            let _: Any = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Any, Error>) in

                functions.httpsCallable("updateDisplayName").call([
                    "displayName": trimmed
                ]) { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let result else {
                        continuation.resume(
                            throwing: AppError.backend(
                                code: "empty_function_result",
                                message: "The server returned no result."
                            )
                        )
                        return
                    }

                    continuation.resume(returning: result.data)
                }
            }

            user.displayName = trimmed
            session.user = user
            return true
        } catch {
            let nsError = error as NSError
            errorMessage = nsError.localizedDescription
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
        Form {
            Section {
                TextField("Your name", text: $model.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
            } header: {
                Text("Display name")
            } footer: {
                Text("People in your trips will see this name. Your Firebase user ID stays private.")
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task {
                        if await model.save(session: session) {
                            onSaved?()
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if model.isSaving {
                            ProgressView()
                        } else {
                            Text("Save Name").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(model.isSaving)
            }
        }
        .navigationTitle("Your Name")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(session: session) }
    }
}
