import SwiftUI

struct BiometricConsentView: View {
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var understandsPurpose = false
    @State private var understandsStorage = false
    @State private var understandsControl = false

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
                                Text("Please review before setting up your face").font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        PremiumCard {
                            VStack(alignment: .leading, spacing: 14) {
                                consentPoint("Purpose", "SnapLoop creates face-template metadata from your Face Setup so participating devices can find photos of you in Trips you join. It is used for photo matching only — not advertising, stranger identification, surveillance, or account authentication.", icon: "sparkles", tint: Theme.sunset)
                                Divider()
                                consentPoint("Your selfie stays on your iPhone", "Guided selfie and gallery reference images are stored only inside SnapLoop's protected app storage on this iPhone. SnapLoop does not upload those reference images or raw guided-scan video.", icon: "iphone.gen3", tint: Theme.aqua)
                                Divider()
                                consentPoint("Face-template metadata", "To enable matching, SnapLoop stores only face-template metadata — not your selfie photo. For an active Trip, authorized participating devices may receive the template data needed to perform matching on-device.", icon: "lock.shield.fill", tint: Theme.violet)
                                Divider()
                                consentPoint("Photo-library scope", "SnapLoop does not upload your entire photo library. On-device scanning is limited to photos available to SnapLoop within the selected Trip date range. Limited Photos access is supported; Full Access provides the most complete automatic discovery.", icon: "photo.on.rectangle.angled", tint: Theme.sky)
                                Divider()
                                consentPoint("Matched-photo privacy", "Only optimized previews of confirmed matches are uploaded. SnapLoop's access controls permit a participant to retrieve a preview only when that participant is matched in the photo. Your original photo remains on the source device unless you explicitly save or transfer it through a supported feature.", icon: "person.crop.square.fill", tint: Theme.aqua)
                                Divider()
                                consentPoint("Retention", "All Trip-related cloud data, including matched photo previews, is deleted within 15 days after the Trip ends. If a Trip is manually deleted, its Trip-related cloud data is also deleted within 15 days of deletion.", icon: "clock.badge.checkmark", tint: Theme.sunset)
                                Divider()
                                consentPoint("Your control", "You can change iOS photo or camera permissions at any time. In Privacy & Data you can remove Face Setup, withdraw biometric consent, or delete your account. Removing Face Setup stops future face matching and requests deletion of the stored face template and matching derivatives.", icon: "lock.shield.fill", tint: Theme.sky)
                            }
                        }

                        Text("Consent").font(.headline).foregroundStyle(Theme.ink)
                        Toggle("I understand SnapLoop uses face-template metadata for Trip photo matching.", isOn: $understandsPurpose).tint(Theme.sunset)
                        Toggle("I understand my selfie images stay on this iPhone, while face-template metadata is stored by SnapLoop for matching.", isOn: $understandsStorage).tint(Theme.sunset)
                        Toggle("I understand I can withdraw consent and remove Face Setup later.", isOn: $understandsControl).tint(Theme.sunset)

                        Text("By tapping I Agree & Continue, you give SnapLoop permission to create, store, use, and disclose your face-template metadata only for the face-matching purposes described above. If you do not agree, choose Not Now and Face Setup will not proceed.")
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                        Button { onAccept(); dismiss() } label: { Label("I Agree & Continue", systemImage: "checkmark.shield.fill") }
                            .buttonStyle(MyPicsTubePrimaryButtonStyle())
                            .disabled(!understandsPurpose || !understandsStorage || !understandsControl)
                            .opacity((!understandsPurpose || !understandsStorage || !understandsControl) ? 0.5 : 1)
                        Button("Not Now", role: .cancel) { dismiss() }.frame(maxWidth: .infinity).foregroundStyle(.secondary)
                    }.padding(22)
                }
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func consentPoint(_ title: String, _ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack { RoundedRectangle(cornerRadius: 11).fill(tint.opacity(0.12)); Image(systemName: icon).foregroundStyle(tint) }.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.bold()).foregroundStyle(Theme.ink); Text(text).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}
