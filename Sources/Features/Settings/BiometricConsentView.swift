import SwiftUI

struct BiometricConsentView: View {
    let consentActive: Bool
    let onAccept: () async -> Bool
    let onWithdraw: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmWithdrawal = false

    var body: some View {
        NavigationStack {
            ZStack {
                BrandScreenBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            BrandMark(size: 54)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Face Match Consent")
                                    .font(.title2.bold())
                                    .foregroundStyle(Theme.ink)
                                Text(consentActive ? "Consent is active" : "Review before Face Setup")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        PremiumCard {
                            VStack(alignment: .leading, spacing: 14) {
                                consentPoint(
                                    "What Face Match uses",
                                    "SnapLoop converts your Face Setup selfie into numeric face-template metadata (face embeddings) only to identify photos of you in Events you choose to join. It is not used for advertising, account authentication, surveillance, stranger identification, or to infer sensitive traits.",
                                    icon: "faceid",
                                    tint: Theme.sunset
                                )
                                Divider()
                                consentPoint(
                                    "Where your data goes",
                                    "Your Face Setup selfie/reference images stay on this iPhone and are not uploaded. Your face-template metadata is stored with your SnapLoop account in Firebase. While you participate in an active Event, that template may be provided only to authenticated participating Event members' devices so matching can run on-device within the Event date range.",
                                    icon: "lock.icloud.fill",
                                    tint: Theme.aqua
                                )
                                Divider()
                                consentPoint(
                                    "Retention and deletion",
                                    "Your account-level face-template metadata is kept until you delete Face Setup, withdraw Face Match consent, or delete your account. Event-related cloud data, including matched photo previews, is deleted within 15 days after an Event ends or is deleted. SnapLoop may retain a limited consent record showing when consent was given or withdrawn for compliance and audit purposes.",
                                    icon: "clock.badge.checkmark",
                                    tint: Theme.violet
                                )
                                Divider()
                                consentPoint(
                                    "Your choice",
                                    "Face Match is optional. You can use SnapLoop without Face Setup. You can withdraw consent at any time from Privacy & Data; withdrawal deletes your Face Setup and stops future face matching. Face Match is intended only for users age 18 or older.",
                                    icon: "hand.raised.fill",
                                    tint: Theme.sunset
                                )
                            }
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        if consentActive {
                            Button(role: .destructive) {
                                confirmWithdrawal = true
                            } label: {
                                Label("Withdraw Consent", systemImage: "hand.raised.slash.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 54)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .disabled(isSaving)

                            Button("Done") { dismiss() }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("By tapping I Agree & Continue, you confirm that you are at least 18 years old and give express consent to the face-template processing described above.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Button {
                                Task { await accept() }
                            } label: {
                                HStack {
                                    if isSaving { ProgressView().tint(.white) }
                                    else { Image(systemName: "checkmark.shield.fill") }
                                    Text("I Agree & Continue")
                                }
                            }
                            .buttonStyle(MyPicsTubePrimaryButtonStyle())
                            .disabled(isSaving)

                            Button("Not Now", role: .cancel) { dismiss() }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(22)
                }
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Withdraw Face Match Consent?",
                isPresented: $confirmWithdrawal,
                titleVisibility: .visible
            ) {
                Button("Withdraw Consent & Delete Face Setup", role: .destructive) {
                    Task { await withdraw() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Withdrawing consent will delete your Face Setup, face-template metadata, and related face-matching data. SnapLoop will no longer be able to find photos of you on other participants' phones until you complete Face Setup and give consent again. This action cannot be undone.")
            }
        }
    }

    @MainActor
    private func accept() async {
        isSaving = true
        errorMessage = nil
        let saved = await onAccept()
        isSaving = false
        if saved {
            dismiss()
        } else {
            errorMessage = "Consent could not be saved. Please try again."
        }
    }

    @MainActor
    private func withdraw() async {
        isSaving = true
        errorMessage = nil
        let withdrawn = await onWithdraw()
        isSaving = false
        if withdrawn {
            dismiss()
        } else {
            errorMessage = "Consent could not be withdrawn. Please try again."
        }
    }

    private func consentPoint(_ title: String, _ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(tint.opacity(0.12))
                Image(systemName: icon).foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.bold()).foregroundStyle(Theme.ink)
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
