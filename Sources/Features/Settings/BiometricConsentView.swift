import StoreKit
import SwiftUI

struct BiometricConsentView: View {
    let consentActive: Bool
    let onAccept: (BiometricJurisdiction) async -> Bool
    let onWithdraw: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var isWithdrawing = false
    @State private var errorMessage: String?
    @State private var confirmWithdrawal = false
    @State private var ageConfirmed = false
    @State private var noticeConfirmed = false
    @State private var launchJurisdiction = BiometricConsentView.localeFallbackJurisdiction()
    @State private var didResolveStorefront = false

    private var canAccept: Bool {
        didResolveStorefront
            && launchJurisdiction.isFaceMatchAvailable
            && ageConfirmed
            && noticeConfirmed
            && !isSaving
    }

    private var countryName: String {
        BiometricJurisdictionCatalog.countryName(for: launchJurisdiction.countryCode)
    }

    private var subdivisionName: String? {
        BiometricJurisdictionCatalog.subdivisionName(
            countryCode: launchJurisdiction.countryCode,
            subdivisionCode: launchJurisdiction.subdivisionCode
        )
    }

    private var residenceAttestation: String {
        if launchJurisdiction.countryCode == "CA", let subdivisionName {
            return "I confirm I am at least 18 years old and ordinarily reside in \(subdivisionName), Canada."
        }
        if launchJurisdiction.countryCode == "IN" {
            return "I confirm I am at least 18 years old and ordinarily reside in India."
        }
        return "Face Match is not available for the selected jurisdiction."
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
            .interactiveDismissDisabled(isSaving)
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
            .task {
                await resolveStorefrontJurisdiction()
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
                launchResidenceCard
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
                    HStack(spacing: 9) {
                        if isWithdrawing {
                            ProgressView().tint(.red)
                            Text("Withdrawing…")
                        } else {
                            Image(systemName: "hand.raised.slash.fill")
                            Text("Withdraw Consent")
                        }
                    }
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
                    .disabled(isSaving)
            } else {
                Button {
                    Task { await accept() }
                } label: {
                    HStack(spacing: 9) {
                        if isSaving {
                            ProgressView().tint(.white)
                            Text("Saving…")
                        } else {
                            Image(systemName: "checkmark.shield.fill")
                            Text("I Agree & Continue")
                        }
                    }
                }
                .buttonStyle(MyPicsTubePrimaryButtonStyle())
                .disabled(!canAccept)
                .opacity(canAccept ? 1 : 0.55)

                Button("Not Now", role: .cancel) { dismiss() }
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .foregroundStyle(.secondary)
                    .disabled(isSaving)
            }
        }
    }

    private var launchResidenceCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Country or region", systemImage: "mappin.and.ellipse")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Picker("Country or region", selection: countrySelection) {
                        ForEach(BiometricJurisdictionCatalog.countries) { country in
                            Text(country.name).tag(country.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.violet)
                    .disabled(!didResolveStorefront || isSaving)
                }

                if launchJurisdiction.countryCode == "CA" {
                    Divider()
                    HStack {
                        Text("Province or territory")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Picker("Province or territory", selection: subdivisionSelection) {
                            ForEach(BiometricJurisdictionCatalog.subdivisions(for: "CA")) { subdivision in
                                Text(subdivision.name).tag(subdivision.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.violet)
                        .disabled(!didResolveStorefront || isSaving)
                    }
                }

                Text("Your selection is used to apply the appropriate privacy and biometric rules. No GPS or precise address is required.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !launchJurisdiction.isFaceMatchAvailable {
                    Text("Face Match is not available for the selected jurisdiction.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
                    text: residenceAttestation
                ) { ageConfirmed.toggle() }

                Divider()

                checkboxRow(
                    checked: noticeConfirmed,
                    text: "I read the Face Match Notice, confirm Face Setup will use my own face only, and expressly consent to the described biometric processing."
                ) { noticeConfirmed.toggle() }
            }
        }
    }

    private var countrySelection: Binding<String> {
        Binding(
            get: { launchJurisdiction.countryCode },
            set: { code in
                launchJurisdiction = BiometricJurisdiction(
                    countryCode: code,
                    subdivisionCode: BiometricJurisdictionCatalog.firstAvailableSubdivision(for: code)
                )
                ageConfirmed = false
                noticeConfirmed = false
            }
        )
    }

    private var subdivisionSelection: Binding<String> {
        Binding(
            get: { launchJurisdiction.subdivisionCode },
            set: { code in
                launchJurisdiction = BiometricJurisdiction(countryCode: "CA", subdivisionCode: code)
                ageConfirmed = false
                noticeConfirmed = false
            }
        )
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
        .disabled(isSaving || !didResolveStorefront || !launchJurisdiction.isFaceMatchAvailable)
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
    private func resolveStorefrontJurisdiction() async {
        guard !consentActive else {
            didResolveStorefront = true
            return
        }

        if let storefront = await Storefront.current {
            switch storefront.countryCode.uppercased() {
            case "CAN":
                launchJurisdiction = BiometricJurisdiction(countryCode: "CA", subdivisionCode: "ON")
            case "IND":
                launchJurisdiction = BiometricJurisdiction(countryCode: "IN")
            default:
                launchJurisdiction = Self.localeFallbackJurisdiction()
            }
            ageConfirmed = false
            noticeConfirmed = false
        }
        didResolveStorefront = true
    }

    private static func localeFallbackJurisdiction() -> BiometricJurisdiction {
        switch Locale.current.region?.identifier.uppercased() {
        case "CA":
            return BiometricJurisdiction(countryCode: "CA", subdivisionCode: "ON")
        case "IN":
            return BiometricJurisdiction(countryCode: "IN")
        case let region?:
            return BiometricJurisdiction(countryCode: region)
        case nil:
            return BiometricJurisdiction(countryCode: "UN")
        }
    }

    @MainActor
    private func accept() async {
        guard canAccept else { return }
        isWithdrawing = false
        isSaving = true
        errorMessage = nil
        let saved = await onAccept(launchJurisdiction)
        isSaving = false
        if saved {
            dismiss()
        } else {
            errorMessage = "Consent could not be saved by the secure Face Match service. Please try again."
        }
    }

    @MainActor
    private func withdraw() async {
        guard !isSaving else { return }
        isWithdrawing = true
        isSaving = true
        errorMessage = nil
        let withdrawn = await onWithdraw()
        isSaving = false
        isWithdrawing = false
        if withdrawn {
            dismiss()
        } else {
            errorMessage = "Consent could not be withdrawn. Please try again."
        }
    }
}
