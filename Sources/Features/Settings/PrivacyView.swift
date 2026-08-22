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
            LocalFaceReferenceStore.delete(userId: userId)
            message = "Your Face Setup was removed. Set it up again whenever you want automatic photo matching."
        } catch { message = AppError.unknown("\(error)").userMessage }
    }

    func deleteAccount() async {
        guard let env, let userId = session?.user?.id else { return }
        busy = true; defer { busy = false }
        do {
            try await env.makeErasureService().deleteAccount(userId: userId)
            LocalFaceReferenceStore.delete(userId: userId)
            session?.user = nil
            session?.faceProfile = nil
            message = "Your SnapLoop account, face data, memberships, and photo previews were deleted."
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
                        .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink).padding(.horizontal)
                    privacyIntro
                    retentionCard
                    deleteFaceCard
                    deleteAccountCard
                    if let message = model.message {
                        PremiumCard { Label(message, systemImage: "info.circle.fill").font(.footnote).foregroundStyle(.secondary) }.padding(.horizontal)
                    }
                }.padding(.vertical, 16)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.configure(env: env, session: session) }
        .confirmationDialog("Delete your Face Setup?", isPresented: $confirmProfile, titleVisibility: .visible) {
            Button("Delete Face Setup", role: .destructive) { Task { await model.deleteFaceProfile() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the local Face Setup images, stored face-template metadata, and matching derivatives. Automatic face matching stops until you set it up again.") }
        .confirmationDialog("Delete your SnapLoop account?", isPresented: $confirmAccount, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await model.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes your account, face data, Event memberships, and photo previews sourced from your account. It cannot be undone.") }
    }

    private var privacyIntro: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("You stay in control", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(Theme.ink)
                Text("SnapLoop never uploads your entire photo library. Photo matching runs on your iPhone and is limited to the selected Event date range. Your Face Setup selfie/reference images stay only on this iPhone; SnapLoop stores only face-template metadata for matching.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.horizontal)
    }

    private var retentionCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Data retention", systemImage: "clock.badge.checkmark").font(.headline).foregroundStyle(Theme.ink)
                Text("All Event-related cloud data, including matched photo previews, is deleted within 15 days after an Event ends. If an Event is manually deleted, its Event-related cloud data is also deleted within 15 days of deletion.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.horizontal)
    }

    private var deleteFaceCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Delete Face Setup", systemImage: "faceid").font(.headline).foregroundStyle(.red)
                Text("Removes your local Face Setup reference images, private face-template metadata, and your face matches from Event metadata. You can set it up again later.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(role: .destructive) { confirmProfile = true } label: { Label("Delete Face Setup", systemImage: "trash.fill") }.disabled(model.busy)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal)
    }

    private var deleteAccountCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Delete Account", systemImage: "person.crop.circle.badge.xmark").font(.headline).foregroundStyle(.red)
                Text("Deletes your account, face data, Event memberships, and photo previews sourced from this account.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(role: .destructive) { confirmAccount = true } label: { Label("Delete SnapLoop Account", systemImage: "trash.fill") }.disabled(model.busy)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal)
    }
}
