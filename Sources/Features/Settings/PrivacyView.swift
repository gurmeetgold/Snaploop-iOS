import SwiftUI

@MainActor
final class PrivacyModel: ObservableObject {
    @Published var busy = false
    @Published var message: String?
    @Published var consentActive = false
    private var env: AppEnvironment?
    private var session: AppSession?

    func configure(env: AppEnvironment, session: AppSession) {
        self.env = env
        self.session = session
    }

    func refreshConsent() async {
        guard let env, let userId = session?.user?.id else {
            consentActive = false
            return
        }
        do {
            consentActive = try await env.biometricConsent.load(userId: userId)?.isActive == true
        } catch {
            consentActive = false
        }
    }

    func acceptConsent(_ jurisdiction: BiometricJurisdiction) async -> Bool {
        guard let env, let userId = session?.user?.id,
              jurisdiction.isFaceMatchAvailable else { return false }
        do {
            try await env.biometricConsent.save(BiometricConsentRecord(
                userId: userId,
                acceptedAt: env.clock.now(),
                jurisdictionCountry: jurisdiction.countryCode,
                jurisdictionSubdivision: jurisdiction.subdivisionCode
            ))
            consentActive = true
            message = nil
            return true
        } catch {
            message = (error as NSError).localizedDescription
            return false
        }
    }

    func withdrawConsent() async -> Bool {
        guard let env, let userId = session?.user?.id else { return false }
        busy = true
        message = nil
        defer { busy = false }

        do {
            try await env.biometricConsent.withdraw(userId: userId, at: env.clock.now())
            LocalFaceReferenceStore.delete(userId: userId)
            session?.requireFaceSetupAfterDeletion()
            consentActive = false
            return true
        } catch {
            message = (error as NSError).localizedDescription
            return false
        }
    }

    func deleteFaceProfile() async {
        guard let env, let userId = session?.user?.id else { return }
        busy = true
        defer { busy = false }
        do {
            try await env.makeErasureService().deleteFaceProfile(userId: userId)
            LocalFaceReferenceStore.delete(userId: userId)
            session?.requireFaceSetupAfterDeletion()
            await refreshConsent()
            message = nil
        } catch {
            message = AppError.unknown("\(error)").userMessage
        }
    }

    func deleteAccount() async {
        guard let env, let userId = session?.user?.id else { return }
        busy = true; defer { busy = false }

        do {
            try await env.makeErasureService().deleteAccount(userId: userId)
            finishLocalAccountDeletion(env: env, userId: userId)
        } catch {
            Log.auth.error("Account deletion callable returned an error: \(String(describing: error), privacy: .public)")
            finishLocalAccountDeletion(env: env, userId: userId)
        }
    }

    private func finishLocalAccountDeletion(env: AppEnvironment, userId: String) {
        LocalFaceReferenceStore.delete(userId: userId)
        do {
            try env.auth.signOut()
        } catch {
            Log.auth.error("Local sign-out after account deletion failed: \(String(describing: error), privacy: .public)")
        }
        session?.clearAuthenticatedSession()
        message = nil
    }
}

struct PrivacyView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var session: AppSession
    @StateObject private var model = PrivacyModel()
    @State private var confirmProfile = false
    @State private var confirmAccount = false
    @State private var showConsent = false

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
                    faceConsentCard
                    retentionCard
                    legalResourcesCard
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
        .task {
            model.configure(env: env, session: session)
            await model.refreshConsent()
        }
        .sheet(isPresented: $showConsent, onDismiss: {
            Task { await model.refreshConsent() }
        }) {
            BiometricConsentView(
                consentActive: model.consentActive,
                onAccept: { jurisdiction in await model.acceptConsent(jurisdiction) },
                onWithdraw: { await model.withdrawConsent() }
            )
        }
        .confirmationDialog("Delete your Face Setup?", isPresented: $confirmProfile, titleVisibility: .visible) {
            Button("Delete Face Setup", role: .destructive) { Task { await model.deleteFaceProfile() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local Face Setup images, stored face-template metadata, and matching derivatives. Automatic face matching stops until you set it up again. Your existing Face Match consent remains on record unless you separately withdraw it or it expires after 12 months without biometric activity.")
        }
        .confirmationDialog("Delete your SnapLoop account?", isPresented: $confirmAccount, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await model.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your account, face data, Event memberships, and photo previews sourced from your account. It cannot be undone.")
        }
    }

    private var privacyIntro: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("You stay in control", systemImage: "hand.raised.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("SnapLoop never uploads your entire photo library. Photo matching runs on participating iPhones and is limited to the selected Event date range. Your Face Setup selfie/reference images stay on this iPhone; SnapLoop stores numerical face-template metadata only for the Face Match purpose you expressly consent to.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private var faceConsentCard: some View {
        PremiumCard {
            Button { showConsent = true } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(model.consentActive ? Color.green.opacity(0.12) : Theme.violet.opacity(0.12))
                        Image(systemName: model.consentActive ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                            .foregroundStyle(model.consentActive ? .green : Theme.violet)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Face Match Consent")
                            .font(.subheadline.bold())
                            .foregroundStyle(Theme.ink)
                        Text(model.consentActive ? "Active · Review or withdraw" : "Not active · Review details")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }

    private var retentionCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Data retention", systemImage: "clock.badge.checkmark")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("Face Match consent and the account-level numerical face template expire after 12 months without biometric activity. They are removed sooner when you withdraw consent, delete Face Setup, or delete your account. Event-related cloud data, including matched photo previews, is deleted within 15 days after an Event ends or is manually deleted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private var legalResourcesCard: some View {
        PremiumCard {
            VStack(spacing: 0) {
                Link(destination: URL(string: "https://getsnaploop.web.app/privacy.html")!) {
                    resourceRow(title: "Privacy Policy", subtitle: "How SnapLoop collects, uses, protects and deletes data", icon: "doc.text.fill")
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 46)

                Link(destination: URL(string: "https://getsnaploop.web.app/privacy.html#face-match-notice")!) {
                    resourceRow(title: "Face Match Biometric Notice", subtitle: "Purpose, consent, candidate-face processing and retention", icon: "checkmark.shield.fill")
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 46)

                NavigationLink { OpenSourceLicensesView() } label: {
                    resourceRow(title: "Open Source Licenses", subtitle: "AuraFace and other applicable license notices", icon: "curlybraces.square.fill")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private func resourceRow(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.violet.opacity(0.12))
                Image(systemName: icon).font(.headline).foregroundStyle(Theme.violet)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold()).foregroundStyle(Theme.ink)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private var deleteFaceCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Delete Face Setup", systemImage: "faceid")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("Removes your local Face Setup reference images, private face-template metadata, and your face matches from Event metadata. You can set it up again later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("Deletes your account, face data, Event memberships, and photo previews sourced from this account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) { confirmAccount = true } label: {
                    Label("Delete SnapLoop Account", systemImage: "trash.fill")
                }
                .disabled(model.busy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
    }
}

struct OpenSourceLicensesView: View {
    @State private var auraFaceLicense = "Loading license notice…"

    var body: some View {
        ZStack {
            BrandScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Open Source Licenses")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)

                    PremiumCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("AuraFace-v1")
                                .font(.headline)
                                .foregroundStyle(Theme.ink)
                            Text("SnapLoop uses an on-device Core ML conversion of AuraFace-v1 to generate numerical face embeddings. AuraFace-v1 is distributed under the Apache License, Version 2.0. SnapLoop's use of open-source face technology does not permit the model publisher to receive or process your Face Setup images.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Divider()
                            Text(auraFaceLicense)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadAuraFaceLicense() }
    }

    private func loadAuraFaceLicense() {
        guard let url = Bundle.main.url(forResource: "AuraFace_LICENSE", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            auraFaceLicense = "AuraFace-v1: Apache License, Version 2.0. The full license notice is included with the SnapLoop application bundle."
            return
        }
        auraFaceLicense = text
    }
}
