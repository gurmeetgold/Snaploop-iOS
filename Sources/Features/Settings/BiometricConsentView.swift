import StoreKit
import SwiftUI

enum ConsentStorefrontResolver {
    /// StoreKit reports ISO 3166-1 alpha-3 storefront codes. SnapLoop stores the
    /// existing alpha-2 jurisdiction codes used by the backend and consent data.
    /// Locale is used only when StoreKit cannot return a storefront at all,
    /// which keeps development/TestFlight flows usable without overriding a
    /// known unsupported App Store storefront.
    static func appCountryCode(storefrontCountryCode: String?, localeRegionCode: String?) -> String? {
        if let storefrontCountryCode {
            switch storefrontCountryCode.uppercased() {
            case "IND": return "IN"
            case "CAN": return "CA"
            default: return nil
            }
        }

        switch localeRegionCode?.uppercased() {
        case "IN": return "IN"
        case "CA": return "CA"
        default: return nil
        }
    }
}

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
    @State private var storefrontCountryCode: String?
    @State private var selectedSubdivision = "ON"
    @State private var storefrontResolved = false

    private var launchJurisdiction: BiometricJurisdiction? {
        guard let storefrontCountryCode else { return nil }
        return BiometricJurisdiction(
            countryCode: storefrontCountryCode,
            subdivisionCode: storefrontCountryCode == "CA" ? selectedSubdivision : ""
        )
    }

    private var countryName: String? {
        switch storefrontCountryCode {
        case "IN": return "India"
        case "CA": return "Canada"
        default: return nil
        }
    }

    private var selectedSubdivisionName: String? {
        guard storefrontCountryCode == "CA" else { return nil }
        return BiometricJurisdictionCatalog.canadianSubdivisions
            .first(where: { $0.code == selectedSubdivision })?.name
    }

    private var canAccept: Bool {
        storefrontResolved
            && launchJurisdiction?.isFaceMatchAvailable == true
            && ageConfirmed
            && noticeConfirmed
            && !isSaving
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
            .task { await resolveStorefrontIfNeeded() }
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
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Residence", systemImage: "mappin.and.ellipse")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    if !storefrontResolved {
                        ProgressView()
                    } else if let countryName {
                        Label(countryName, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(Theme.violet)
                    } else {
                        Text("Unavailable")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                    }
                }

                if storefrontCountryCode == "CA" {
                    Divider()
                    Picker("Province or territory", selection: $selectedSubdivision) {
                        ForEach(BiometricJurisdictionCatalog.canadianSubdivisions) { subdivision in
                            Text(subdivision.name).tag(subdivision.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.violet)
                }

                if let countryName {
                    Text("SnapLoop uses your App Store storefront to preselect \(countryName). Confirm below that this is where you ordinarily reside. No GPS or precise address is required.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if storefrontResolved {
                    Text("Face Match is not currently available for this App Store storefront.")
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
                    text: residenceAttestationText
                ) { ageConfirmed.toggle() }
                .disabled(launchJurisdiction?.isFaceMatchAvailable != true)

                Divider()

                checkboxRow(
                    checked: noticeConfirmed,
                    text: "I read the Face Match Notice, confirm Face Setup will use my own face only, and expressly consent to the described biometric processing."
                ) { noticeConfirmed.toggle() }
                .disabled(launchJurisdiction?.isFaceMatchAvailable != true)
            }
        }
    }

    private var residenceAttestationText: String {
        if storefrontCountryCode == "CA", let selectedSubdivisionName {
            return "I confirm I am at least 18 years old and ordinarily reside in \(selectedSubdivisionName), Canada."
        }
        if storefrontCountryCode == "IN" {
            return "I confirm I am at least 18 years old and ordinarily reside in India."
        }
        return "I confirm I am at least 18 years old and ordinarily reside in the supported jurisdiction shown above."
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
        .disabled(isSaving)
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
    private func resolveStorefrontIfNeeded() async {
        guard !storefrontResolved else { return }
        let storefront = await Storefront.current
        let resolved = ConsentStorefrontResolver.appCountryCode(
            storefrontCountryCode: storefront?.countryCode,
            localeRegionCode: Locale.current.region?.identifier
        )
        storefrontCountryCode = resolved
        selectedSubdivision = BiometricJurisdictionCatalog.firstAvailableSubdivision(for: resolved ?? "")
        ageConfirmed = false
        noticeConfirmed = false
        storefrontResolved = true
    }

    @MainActor
    private func accept() async {
        guard canAccept, let launchJurisdiction else { return }
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
