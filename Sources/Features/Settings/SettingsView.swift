import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var errorMessage: String?

    func signOut(env: AppEnvironment, session: AppSession) {
        do {
            try env.auth.signOut()
            session.user = nil
            session.faceProfile = nil
            session.activeEvent = nil
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.unknown("\(error)").userMessage
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = SettingsModel()
    @State private var confirmSignOut = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Theme.coralGradient)
                        Text(String((session.user?.displayName ?? "?").prefix(1)).uppercased())
                            .font(.title2).bold().foregroundStyle(.white)
                    }
                    .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.user?.displayName ?? "You").font(.headline)
                        if let phone = session.user?.phoneNumber {
                            Text(phone).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)

                NavigationLink { FaceSetupView() } label: {
                    Label(session.hasFaceProfile ? "Update Face Setup" : "Set Up Your Face",
                          systemImage: "faceid")
                }
            }

            Section {
                NavigationLink { PrivacyView() } label: {
                    Label("Privacy & Data", systemImage: "lock.shield")
                }
            }

            Section {
                Button(role: .destructive) { confirmSignOut = true } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }

                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                Text("SnapLoop finds your photos from trips on-device. Your photos stay on your phone unless you're in them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("You")
        .confirmationDialog("Sign out of SnapLoop?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                model.signOut(env: env, session: session)
            }
        }
    }
}
