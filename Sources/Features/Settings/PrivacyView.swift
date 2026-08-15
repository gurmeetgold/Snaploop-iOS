import SwiftUI

@MainActor
final class PrivacyModel: ObservableObject {
    @Published var busy = false
    @Published var message: String?
    private var env: AppEnvironment?
    private var session: AppSession?
    func configure(env: AppEnvironment, session: AppSession) { self.env = env; self.session = session }

    func deleteFaceProfile() async {
        guard let env, let userId = session?.user?.id else { return }
        busy = true; defer { busy = false }
        do {
            try await env.makeErasureService().deleteFaceProfile(userId: userId)
            session?.faceProfile = nil
            message = "Your face setup was removed. You'll need to set it up again to be matched in photos."
        } catch { message = AppError.unknown("\(error)").userMessage }
    }

    func deleteAccount() async {
        guard let env, let userId = session?.user?.id else { return }
        busy = true; defer { busy = false }
        do {
            try await env.makeErasureService().deleteAccount(userId: userId)
            session?.user = nil; session?.faceProfile = nil
            message = "Your account and face data were deleted."
        } catch { message = AppError.unknown("\(error)").userMessage }
    }
}

/// Privacy & data controls. The erase actions should ship before any real users
/// touch the app.
struct PrivacyView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = PrivacyModel()
    @State private var confirmProfile = false
    @State private var confirmAccount = false

    var body: some View {
        List {
            Section {
                Button(role: .destructive) { confirmProfile = true } label: {
                    Label("Delete Face Setup", systemImage: "faceid")
                }
            } footer: {
                Text("Removes your face data. You can set it up again anytime to keep getting your photos.")
            }

            Section {
                Button(role: .destructive) { confirmAccount = true } label: {
                    Label("Delete Account", systemImage: "trash")
                }
            } footer: {
                Text("Deletes your account and face data. Photos you took stay part of the events you shared them to, but your personal data and face setup are permanently removed.")
            }

            if let message = model.message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Privacy")
        .task { model.configure(env: env, session: session) }
        .confirmationDialog("Delete your face setup?", isPresented: $confirmProfile, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.deleteFaceProfile() } }
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmAccount, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { Task { await model.deleteAccount() } }
        } message: {
            Text("This can't be undone.")
        }
    }
}
