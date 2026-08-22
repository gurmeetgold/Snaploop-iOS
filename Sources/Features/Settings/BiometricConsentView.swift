import SwiftUI

struct BiometricConsentView: View {
    let onAccept: () async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var agreed = false
    @State private var isSaving = false
    @State private var errorMessage: String?

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
                                Text("Review once before Face Setup")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        PremiumCard {
                            VStack(alignment: .leading, spacing: 14) {
                                consentPoint(
                                    "Face matching only",
                                    "SnapLoop uses face-template metadata only to find photos of you in Events you join. It is not used for advertising, surveillance, stranger identification, or account authentication.",
                                    icon: "faceid",
                                    tint: Theme.sunset
                                )
                                Divider()
                                consentPoint(
                                    "Your selfie stays on your iPhone",
                                    "Your selfie and optional gallery reference image are not uploaded. SnapLoop stores face-template metadata - not your selfie photo.",
                                    icon: "iphone.gen3",
                                    tint: Theme.aqua
                                )
                                Divider()
                                consentPoint(
                                    "On-device and under your control",
                                    "Matching runs on participating devices and only within each Event's selected date range. You can remove Face Setup or withdraw consent at any time.",
                                    icon: "lock.shield.fill",
                                    tint: Theme.violet
                                )
                            }
                        }

                        Toggle(
                            "I agree to SnapLoop using my face-template metadata only for photo matching in Events I join.",
                            isOn: $agreed
                        )
                        .tint(Theme.sunset)

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        Button {
                            Task {
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
                        } label: {
                            HStack {
                                if isSaving { ProgressView().tint(.white) }
                                else { Image(systemName: "checkmark.shield.fill") }
                                Text("I Agree & Continue")
                            }
                        }
                        .buttonStyle(MyPicsTubePrimaryButtonStyle())
                        .disabled(!agreed || isSaving)
                        .opacity((!agreed || isSaving) ? 0.5 : 1)

                        Button("Not Now", role: .cancel) { dismiss() }
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.secondary)
                    }
                    .padding(22)
                }
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
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
