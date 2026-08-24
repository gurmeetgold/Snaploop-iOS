import SwiftUI

struct BiometricConsentView: View {
    let consentActive: Bool
    let onAccept: (BiometricJurisdiction) async -> Bool
    let onWithdraw: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmWithdrawal = false
    @State private var selectedCountry = "CA"
    @State private var selectedSubdivision = "ON"

    private var subdivisions: [BiometricJurisdictionOption] {
        BiometricJurisdictionCatalog.subdivisions(for: selectedCountry)
    }

    private var selectedJurisdiction: BiometricJurisdiction {
        BiometricJurisdiction(
            countryCode: selectedCountry,
            subdivisionCode: selectedSubdivision
        )
    }

    private var jurisdictionAvailabilityMessage: String? {
        guard !selectedJurisdiction.isFaceMatchAvailable else { return nil }
        if selectedCountry == "CA" && selectedSubdivision == "QC" {
            return "Face Match is not currently available to users who ordinarily reside in Quebec. You can continue using SnapLoop without Face Match."
        }
        if selectedCountry == "US" && selectedSubdivision == "IL" {
            return "Face Match is not currently available to users who ordinarily reside in Illinois. You can continue using SnapLoop without Face Match."
        }
        return "Face Match is not currently available in the selected jurisdiction."
    }

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
                                    "SnapLoop converts your Face Setup selfie into numeric face-template metadata (face embeddings) only to identify photos of you in Events you choose to join. It is not used for advertising, account authentication, surveillance, stranger identification, law-enforcement identification, sensitive-trait inference, or unrelated model training.",
                                    icon: "faceid",
                                    tint: Theme.sunset
                                )
                                Divider()
                                consentPoint(
                                    "Where your data goes",
                                    "Your Face Setup selfie/reference images stay on this iPhone and are not uploaded. Your numerical face template is stored with your SnapLoop account in Firebase. During an active Event, it may be provided only to authenticated Event-member devices so matching can run on-device within the Event date range.",
                                    icon: "lock.icloud.fill",
                                    tint: Theme.aqua
                                )
                                Divider()
                                consentPoint(
                                    "Other faces in Event photos",
                                    "To find a consenting participant in a group photo, an iPhone may temporarily detect other faces and create candidate embeddings in memory. Unmatched candidate embeddings are not uploaded, saved as account profiles, written to disk by the matching workflow, used for analytics, or used to train the face model.",
                                    icon: "person.3.fill",
                                    tint: Theme.violet
                                )
                                Divider()
                                consentPoint(
                                    "12-month biometric expiry",
                                    "Your active Face Match consent and account-level face template expire after 12 months (365 days) without Face Match activity initiated by your account. Another participant merely retrieving or using your template does not extend your retention period. They are deleted or disabled sooner if you delete Face Setup, withdraw consent, or delete your account. After expiry, Face Setup and consent are required again.",
                                    icon: "clock.badge.checkmark",
                                    tint: Theme.violet
                                )
                                Divider()
                                consentPoint(
                                    "Your choice",
                                    "Face Match is optional. You can use non-biometric parts of SnapLoop without it. You can withdraw consent at any time from Privacy & Data; withdrawal deletes the active Face Setup and stops future face matching. Face Match is intended only for users age 18 or older.",
                                    icon: "hand.raised.fill",
                                    tint: Theme.sunset
                                )
                            }
                        }

                        if !consentActive {
                            jurisdictionCard
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
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
                            Text("By tapping I Agree & Continue, you confirm that you are at least 18 years old, that the jurisdiction you selected is where you ordinarily reside, that you have reviewed this notice, and that you expressly consent to the biometric processing described above.")
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
                            .disabled(isSaving || !selectedJurisdiction.isFaceMatchAvailable)
                            .opacity(selectedJurisdiction.isFaceMatchAvailable ? 1 : 0.55)

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
                Text("Withdrawing consent will delete your active Face Setup, face-template metadata, and related face-matching data. SnapLoop will no longer be able to find photos of you on other participants' phones until you complete Face Setup and give consent again. This action cannot be undone.")
            }
        }
    }

    private var jurisdictionCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Face Match availability", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)

                Text("Select where you ordinarily reside. SnapLoop stores only the country and province/state code for biometric-compliance purposes; this does not require GPS or your precise address.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Country", selection: $selectedCountry) {
                    ForEach(BiometricJurisdictionCatalog.countries) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedCountry) { _, newCountry in
                    selectedSubdivision = BiometricJurisdictionCatalog.subdivisions(for: newCountry).first?.code ?? ""
                }

                Picker(selectedCountry == "CA" ? "Province or territory" : "State or territory", selection: $selectedSubdivision) {
                    ForEach(subdivisions) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)

                if let jurisdictionAvailabilityMessage {
                    Label(jurisdictionAvailabilityMessage, systemImage: "info.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @MainActor
    private func accept() async {
        guard selectedJurisdiction.isFaceMatchAvailable else { return }
        isSaving = true
        errorMessage = nil
        let saved = await onAccept(selectedJurisdiction)
        isSaving = false
        if saved {
            dismiss()
        } else {
            errorMessage = "Consent could not be saved. Please check your connection and try again."
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
