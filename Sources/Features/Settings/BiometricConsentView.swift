import SwiftUI

struct BiometricConsentView: View {
    let onAccept: () -> Void

    @Environment(\.dismiss)
    private var dismiss

    @State private var understandsPurpose = false
    @State private var understandsDeletion = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: 18
                ) {
                    Image(
                        systemName: "faceid"
                    )
                    .font(.system(size: 48))
                    .foregroundStyle(
                        Theme.coralGradient
                    )

                    Text(
                        "Face Match Consent"
                    )
                    .font(.title2)
                    .bold()

                    Text(
                        "SnapLoop uses a face template to find photos of you inside trips you join."
                    )
                    .font(.headline)

                    consentPoint(
                        "Purpose",
                        "Your face template is used only to match you in photos for joined SnapLoop trips. It is not used for advertising, marketing, stranger identification, or Face ID login."
                    )

                    consentPoint(
                        "What is stored",
                        "SnapLoop keeps mathematical face descriptors. Raw guided-scan video is not saved. The selected local reference image stays on this device."
                    )

                    consentPoint(
                        "Sharing",
                        "Event-scoped descriptors may be made available to authorized trip members' devices so matching can happen on-device. We will harden this further before commercial launch."
                    )

                    consentPoint(
                        "Your control",
                        "You can update Face Setup or withdraw Face Match later. Withdrawal is designed to delete your biometric template and stop future automatic matching."
                    )

                    Toggle(
                        "I understand why SnapLoop uses my face data.",
                        isOn: $understandsPurpose
                    )

                    Toggle(
                        "I understand I can withdraw Face Match later.",
                        isOn: $understandsDeletion
                    )

                    Button {
                        onAccept()
                        dismiss()
                    } label: {
                        Text(
                            "I Agree & Continue"
                        )
                        .frame(
                            maxWidth: .infinity
                        )
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .controlSize(.large)
                    .disabled(
                        !understandsPurpose
                        || !understandsDeletion
                    )

                    Button(
                        "Not Now",
                        role: .cancel
                    ) {
                        dismiss()
                    }
                    .frame(
                        maxWidth: .infinity
                    )
                }
                .padding(24)
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(
                .inline
            )
        }
    }

    private func consentPoint(
        _ title: String,
        _ text: String
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 5
        ) {
            Text(title)
                .font(.subheadline)
                .bold()

            Text(text)
                .font(.footnote)
                .foregroundStyle(
                    .secondary
                )
        }
    }
}
