import Foundation

public struct BiometricJurisdictionOption: Identifiable, Hashable, Sendable {
    public let code: String
    public let name: String
    public var id: String { code }

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

/// Minimal jurisdiction information used only to decide whether Face Match can
/// be offered. SnapLoop does not need GPS or a precise address for this
/// decision; the user declares where they ordinarily reside before giving
/// biometric consent.
public struct BiometricJurisdiction: Equatable, Codable, Sendable {
    public let countryCode: String
    public let subdivisionCode: String

    public init(countryCode: String, subdivisionCode: String = "") {
        self.countryCode = countryCode.uppercased()
        self.subdivisionCode = subdivisionCode.uppercased()
    }

    public var isFaceMatchAvailable: Bool {
        switch countryCode {
        case "IN":
            return subdivisionCode.isEmpty
        case "CA":
            return BiometricJurisdictionCatalog.canada.contains(where: { $0.code == subdivisionCode })
                && !BiometricJurisdictionCatalog.blockedCanada.contains(subdivisionCode)
        default:
            return false
        }
    }
}

public enum BiometricJurisdictionCatalog {
    /// India is first because it is the default Face Match jurisdiction in the
    /// consent UI. India does not require state selection for this control.
    /// The United States is intentionally not offered at launch.
    public static let countries = [
        BiometricJurisdictionOption(code: "IN", name: "India"),
        BiometricJurisdictionOption(code: "CA", name: "Canada")
    ]

    /// Quebec is intentionally unavailable at launch because its biometric
    /// regime includes requirements beyond ordinary app consent, including
    /// Commission disclosure requirements for biometric systems/databases.
    public static let blockedCanada: Set<String> = ["QC"]

    public static let canada = [
        BiometricJurisdictionOption(code: "AB", name: "Alberta"),
        BiometricJurisdictionOption(code: "BC", name: "British Columbia"),
        BiometricJurisdictionOption(code: "MB", name: "Manitoba"),
        BiometricJurisdictionOption(code: "NB", name: "New Brunswick"),
        BiometricJurisdictionOption(code: "NL", name: "Newfoundland and Labrador"),
        BiometricJurisdictionOption(code: "NS", name: "Nova Scotia"),
        BiometricJurisdictionOption(code: "NT", name: "Northwest Territories"),
        BiometricJurisdictionOption(code: "NU", name: "Nunavut"),
        BiometricJurisdictionOption(code: "ON", name: "Ontario"),
        BiometricJurisdictionOption(code: "PE", name: "Prince Edward Island"),
        BiometricJurisdictionOption(code: "QC", name: "Quebec"),
        BiometricJurisdictionOption(code: "SK", name: "Saskatchewan"),
        BiometricJurisdictionOption(code: "YT", name: "Yukon")
    ]

    public static func subdivisions(for countryCode: String) -> [BiometricJurisdictionOption] {
        switch countryCode.uppercased() {
        case "CA": return canada
        default: return []
        }
    }

    public static func firstAvailableSubdivision(for countryCode: String) -> String {
        subdivisions(for: countryCode).first(where: {
            BiometricJurisdiction(countryCode: countryCode, subdivisionCode: $0.code).isFaceMatchAvailable
        })?.code ?? ""
    }
}

/// A narrow, auditable record of consent for SnapLoop face matching.
///
/// This record does not contain biometric data. It records what the user
/// affirmatively agreed to, when they agreed, the jurisdiction used for
/// feature availability, and the immutable disclosure version/hash.
public struct BiometricConsentRecord: Equatable, Codable, Sendable {
    /// v5 adds the explicit account-holder-only Face Setup rule, identity-bound
    /// matched-photo lifecycle, and fresh consent after Face Setup deletion.
    public static let currentPolicyVersion = 5
    public static let currentDisclosureId = "biometric-consent-v5"
    public static let currentDisclosureSHA256 = "2b78a5de4ced7219953cf4c3b62e07dce41392b0090f7c07c3fcb307411bc30f"
    public static let consentMethod = "explicit-button"

    public let userId: String
    public let policyVersion: Int
    public let disclosureId: String
    public let disclosureSHA256: String
    public let acceptedAt: Date
    public var withdrawnAt: Date?
    public var expiredAt: Date?
    /// Server-issued deadline for the current active consent window. This is
    /// separate from `expiredAt`, which records that expiry has been processed.
    public var expiresAt: Date?
    public let jurisdictionCountry: String
    public let jurisdictionSubdivision: String
    public let appVersion: String
    public let platform: String
    public let locale: String
    public let acceptedVia: String
    public let age18Attested: Bool
    public let noticeAcknowledged: Bool
    public var lastBiometricActivityAt: Date?

    /// This initializer is used by the explicit Face Match acceptance path.
    /// Firebase reads pass the stored attestation values explicitly, so a
    /// missing/legacy server field still decodes as false and cannot become
    /// active accidentally.
    public init(
        userId: String,
        policyVersion: Int = Self.currentPolicyVersion,
        disclosureId: String = Self.currentDisclosureId,
        disclosureSHA256: String = Self.currentDisclosureSHA256,
        acceptedAt: Date,
        withdrawnAt: Date? = nil,
        expiredAt: Date? = nil,
        expiresAt: Date? = nil,
        jurisdictionCountry: String = "",
        jurisdictionSubdivision: String = "",
        appVersion: String? = nil,
        platform: String = "iOS",
        locale: String? = nil,
        acceptedVia: String = Self.consentMethod,
        age18Attested: Bool = true,
        noticeAcknowledged: Bool = true,
        lastBiometricActivityAt: Date? = nil
    ) {
        self.userId = userId
        self.policyVersion = policyVersion
        self.disclosureId = disclosureId
        self.disclosureSHA256 = disclosureSHA256
        self.acceptedAt = acceptedAt
        self.withdrawnAt = withdrawnAt
        self.expiredAt = expiredAt
        self.expiresAt = expiresAt
        self.jurisdictionCountry = jurisdictionCountry.uppercased()
        self.jurisdictionSubdivision = jurisdictionSubdivision.uppercased()
        self.appVersion = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        self.platform = platform
        self.locale = locale ?? Locale.current.identifier
        self.acceptedVia = acceptedVia
        self.age18Attested = age18Attested
        self.noticeAcknowledged = noticeAcknowledged
        self.lastBiometricActivityAt = lastBiometricActivityAt
    }

    public var jurisdiction: BiometricJurisdiction {
        BiometricJurisdiction(
            countryCode: jurisdictionCountry,
            subdivisionCode: jurisdictionSubdivision
        )
    }

    public var isActive: Bool {
        policyVersion == Self.currentPolicyVersion
            && disclosureId == Self.currentDisclosureId
            && disclosureSHA256 == Self.currentDisclosureSHA256
            && withdrawnAt == nil
            && expiredAt == nil
            && (expiresAt.map { $0 > Date() } ?? false)
            && age18Attested
            && noticeAcknowledged
            && jurisdiction.isFaceMatchAvailable
    }
}
