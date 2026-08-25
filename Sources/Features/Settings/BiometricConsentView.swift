import SwiftUI

struct BiometricConsentView: View {
    let consentActive: Bool
    let onAccept: (BiometricJurisdiction) async -> Bool
    let onWithdraw: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmWithdrawal = false
    @State private var selectedCountry = "IN"
    @State private var selectedSubdivision = ""
    @State private var ageConfirmed = false
    @State private var noticeConfirmed = false

    private var subdivisions: [BiometricJurisdictionOption] {
        BiometricJurisdictionCatalog.subdivisions(for: selectedCountry)
    }

    private var selectedJurisdiction: BiometricJurisdiction {
        BiometricJurisdiction(
            countryCode: selectedCountry,
            subdivisionCode: selectedSubdivision
        )
    }

    private var canAccept: Bool {
        selectedJurisdiction.isFaceMatchAvailable
            && ageConfirmed
            && noticeConfirmed
            && !isSaving
    }

    private var requiresSubdivision: Bool {
        selectedCountry == "CA"
    }

    private var jurisdictionAvailabilityMessage: String? {
        guard !selectedJurisdiction.isFaceMatchAvailable else { return nil }
        if selectedCountry == "CA" && selectedSubdivision == "QC" {
            return "Face Match is not currently available in Quebec. You can use SnapLoop without Face Match."
        }
        return "Face Match is not currently available in the selected jurisdiction."
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BrandScreenBackground()
                ViewThatFits(in: .vertical) {
                    consentContent(compact: true)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)

                    ScrollView {
                        consentContent(compact: false)
                            .padding(20)
                    }
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
                Text("This deletes your active Face Setup and related face-matching data and stops Face Match until you consent and set it up again.")
            }
        }
    }

    @ViewBuilder
    private func consentContent(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(spacing: 10) {
                BrandMark(size: compact ? 42 : 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Face Match Consent")
                        .font(.title3.bold())
                        .foregroundStyle(Theme.ink)
                    if consentActive {
                        Text("Consent is active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            PremiumCard {
                VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                    compactPoint(
                        "Purpose & storage",
                        "Your selfie stays on this iPhone. SnapLoop stores a numerical face template in Firebase only to find photos of you in Events you join.",
                        icon: "faceid"
                    )
                    Divider()
                    compactPoint(
                        "Event matching",
                        "Your template may be sent only to authenticated Event-member devices for on-device matching. Unmatched candidate faces are temporary and are not uploaded or saved.",
                        icon: "person.3.fill"
                    )
                    Divider()
                    compactPoint(
                        "Limits",
                        "No sale, ads, account authentication, surveillance, stranger identification, sensitive-trait inference, analytics, or unrelated model training.",
                        icon: "lock.shield.fill"
                    )
                    Divider()
                    compactPoint(
                        "Retention & choice",
                        "Face Match is optional. Consent and your account-level template expire after 12 months without your Face Match activity; you can withdraw consent or delete Face Setup sooner.",
                        icon: "clock.badge.checkmark"
                    )

                    Link(destination: URL(string: "https://getsnaploop.web.app/privacy.html#face-match-notice")!) {
                        Label("Read full Face Match Notice", systemImage: "doc.text.fill")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.violet)
                    }
                }
            }

            if !consentActive {
                compactJurisdictionCard
                compactAttestationCard
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if consentActive {
                Button(role: .destructive) {
                    confirmWithdrawal = true
                } label: {
                    Label("Withdraw Consent", systemImage: "hand.raised.slash.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(isSaving)

                Button("Done") { dismiss() }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(.secondary)
            } else {
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
                .disabled(!canAccept)
                .opacity(canAccept ? 1 : 0.55)

                Button("Not Now", role: .cancel) { dismiss() }
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var compactJurisdictionCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Residence", systemImage: "mappin.and.ellipse")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Picker("Country", selection: $selectedCountry) {
                        ForEach(BiometricJurisdictionCatalog.countries) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if requiresSubdivision {
                    HStack {
                        Text("Province / territory")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Region", selection: $selectedSubdivision) {
                            ForEach(subdivisions) { option in
                                Text(option.name).tag(option.code)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Text("Used only for Face Match availability; no GPS or precise address is required.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let jurisdictionAvailabilityMessage {
                    Label(jurisdictionAvailabilityMessage, systemImage: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: selectedCountry) { _, newCountry in
            selectedSubdivision = BiometricJurisdictionCatalog.firstAvailableSubdivision(for: newCountry)
            errorMessage = nil
        }
    }

    private var compactAttestationCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 7) {
                Text("Confirm before continuing")
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.ink)

                checkboxRow(
                    checked: ageConfirmed,
                    text: "I confirm I am at least 18 years old."
                ) { ageConfirmed.toggle() }

                Divider()

                checkboxRow(
                    checked: noticeConfirmed,
                    text: "I read the Face Match Notice, confirm Face Setup will use my own face only, and expressly consent to the described biometric processing."
                ) { noticeConfirmed.toggle() }
            }
        }
    }

    private func checkboxRow(checked: Bool, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(checked ? Theme.coral : .secondary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(checked ? "Selected" : "Not selected")
    }

    private func compactPoint(_ title: String, _ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.subheadline.bold())
                .foregroundStyle(Theme.violet)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(Theme.ink)
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @MainActor
    private func accept() async {
        guard canAccept else { return }
        isSaving = true
        errorMessage = nil
        let saved = await onAccept(selectedJurisdiction)
        isSaving = false
        if saved {
            dismiss()
        } else {
            errorMessage = "Consent could not be saved by the secure Face Match service. Please try again."
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
}
