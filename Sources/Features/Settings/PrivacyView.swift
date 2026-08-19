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
            message = "Your Face Setup was removed. Set it up again whenever you want automatic photo matching."
        } catch { message = AppError.unknown("\(error)").userMessage }
    }

    func deleteAccount() async {
        guard let env, let userId = session?.user?.id else { return }
        busy = true; defer { busy = false }
        do {
            try await env.makeErasureService().deleteAccount(userId: userId)
            session?.user = nil
            session?.faceProfile = nil
            message = "Your MyPicsRoom account and face data were deleted."
        } catch { message = AppError.unknown("\(error)").userMessage }
    }
}

struct PrivacyView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = PrivacyModel()
    @State private var confirmProfile = false
    @State private var confirmAccount = false

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Privacy & Data", systemImage: "lock.shield.fill")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal)

                    privacyIntro
                    deleteFaceCard
                    deleteAccountCard

                    if let message = model.message {
                        PremiumCard {
                            Label(message, systemImage: "info.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session) }
        .confirmationDialog("Delete your Face Setup?", isPresented: $confirmProfile, titleVisibility: .visible) {
            Button("Delete Face Setup", role: .destructive) { Task { await model.deleteFaceProfile() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Automatic face matching will stop until you set it up again.")
        }
        .confirmationDialog("Delete your MyPicsRoom account?", isPresented: $confirmAccount, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await model.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your account and face data and cannot be undone.")
        }
    }

    private var privacyIntro: some View {
        PremiumCard {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.aqua.opacity(0.13))
                    Image(systemName: "hand.raised.fill").foregroundStyle(Theme.aqua)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 5) {
                    Text("You stay in control").font(.headline).foregroundStyle(Theme.ink)
                    Text("Face matching is for photo discovery. Raw guided-scan video is not saved, and deletion controls are available here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
    }

    private var deleteFaceCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Delete Face Setup", systemImage: "faceid")
                    .font(.headline).foregroundStyle(.red)
                Text("Removes your face data. You can set it up again later if you want automatic photo matching.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(role: .destructive) { confirmProfile = true } label: {
                    Label("Delete Face Setup", systemImage: "trash.fill")
                }
                .disabled(model.busy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
    }

    private var deleteAccountCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Delete Account", systemImage: "person.crop.circle.badge.xmark")
                    .font(.headline).foregroundStyle(.red)
                Text("Deletes your account and face data. Photos already shared to events can remain part of those event albums, but your personal account data is removed.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(role: .destructive) { confirmAccount = true } label: {
                    Label("Delete MyPicsRoom Account", systemImage: "trash.fill")
                }
                .disabled(model.busy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
    }
}
