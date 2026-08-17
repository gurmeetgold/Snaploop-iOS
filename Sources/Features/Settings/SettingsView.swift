import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var errorMessage: String?

    func signOut(env: AppEnvironment, session: AppSession) {
        do {
            try env.auth.signOut()
            session.clearAuthenticatedSession()
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
                        Text(profileInitial)
                            .font(.title2)
                            .bold()
                            .foregroundStyle(.white)
                    }
                    .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.user?.displayName ?? "Add your name")
                            .font(.headline)

                        if let phone = session.user?.phoneNumber {
                            Text(phone)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)

                NavigationLink {
                    ProfileNameView()
                } label: {
                    Label(session.user?.displayName == nil ? "Add Your Name" : "Edit Your Name", systemImage: "person.text.rectangle")
                }

                NavigationLink {
                    FaceSetupView()
                } label: {
                    Label(session.hasFaceProfile ? "Update Face Setup" : "Set Up Your Face", systemImage: "faceid")
                }

                if session.hasFaceProfile {
                    NavigationLink {
                        FaceMatchingTestView()
                    } label: {
                        Label("Test My Face Setup", systemImage: "checkmark.viewfinder")
                    }
                }
            }

            Section {
                NavigationLink { PrivacyView() } label: {
                    Label("Privacy & Data", systemImage: "lock.shield")
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }

                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                Text("SnapLoop finds confident photo matches from your events on-device. Only matched optimized previews are shared with event members in the current MVP.")
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

    private var profileInitial: String {
        if let name = session.user?.displayName, let first = name.first { return String(first).uppercased() }
        return "?"
    }
}
