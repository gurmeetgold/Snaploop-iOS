import SwiftUI

struct BiometricConsentView: View {
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var understandsPurpose = false
    @State private var understandsDeletion = false

    var body: some View {
        NavigationStack {
            ZStack {
                BrandScreenBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            BrandMark(size: 54)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Face Match Consent").font(.title2.bold()).foregroundStyle(Theme.ink)
                                Text("Optional biometric setup for photo discovery")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        PremiumCard {
                            VStack(alignment: .leading, spacing: 14) {
                                consentPoint("Purpose", "MyPicsTube uses your face template only to help find photos of you in events you join. It is not used for advertising, stranger identification, or account authentication.", icon: "sparkles", tint: Theme.sunset)
                                Divider()
                                consentPoint("What is stored", "MyPicsTube stores mathematical face descriptors. Raw guided-scan video is not saved. The reference preview shown in Face Setup stays on this device.", icon: "function", tint: Theme.violet)
                                Divider()
                                consentPoint("Event matching", "For the current MVP, event-scoped descriptors can be shared with authorized event members' devices so matching can happen on-device.", icon: "person.2.fill", tint: Theme.aqua)
                                Divider()
                                consentPoint("Your control", "You can update Face Setup or delete your face data later from Privacy & Data.", icon: "lock.shield.fill", tint: Theme.sky)
                            }
                        }

                        Toggle("I understand why MyPicsTube uses my face data.", isOn: $understandsPurpose)
                            .tint(Theme.sunset)
                        Toggle("I understand I can delete Face Setup later.", isOn: $understandsDeletion)
                            .tint(Theme.sunset)

                        Button {
                            onAccept()
                            dismiss()
                        } label: {
                            Label("I Agree & Continue", systemImage: "checkmark.shield.fill")
                        }
                        .buttonStyle(MyPicsTubePrimaryButtonStyle())
                        .disabled(!understandsPurpose || !understandsDeletion)
                        .opacity((!understandsPurpose || !understandsDeletion) ? 0.5 : 1)

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
