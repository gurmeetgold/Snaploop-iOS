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
        case "US":
            return BiometricJurisdictionCatalog.unitedStates.contains(where: { $0.code == subdivisionCode })
                && !BiometricJurisdictionCatalog.blockedUnitedStates.contains(subdivisionCode)
        default:
            return false
        }
    }
}

public enum BiometricJurisdictionCatalog {
    /// India is first because it is the default Face Match jurisdiction in the
    /// consent UI. India does not require state selection for this control.
    public static let countries = [
        BiometricJurisdictionOption(code: "IN", name: "India"),
        BiometricJurisdictionOption(code: "CA", name: "Canada"),
        BiometricJurisdictionOption(code: "US", name: "United States")
    ]

    /// Quebec is intentionally unavailable at launch because its biometric
    /// regime includes requirements beyond ordinary app consent, including
    /// Commission disclosure requirements for biometric systems/databases.
    public static let blockedCanada: Set<String> = ["QC"]

    /// Conservative U.S. launch blocklist. It covers states with dedicated
    /// biometric statutes, enacted comprehensive privacy regimes that regulate
    /// biometric/sensitive data, and New York because local biometric rules can
    /// apply within New York City. The private server policy can block more
    /// jurisdictions immediately without an App Store release.
    public static let blockedUnitedStates: Set<String> = [
        "AL", "CA", "CO", "CT", "DE", "FL", "IA", "IL", "IN", "KY", "LA", "MD", "MN",
        "MT", "NE", "NH", "NJ", "NY", "OK", "OR", "RI", "TN", "TX", "UT", "VA", "VT", "WA"
    ]

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

    public static let unitedStates = [
        BiometricJurisdictionOption(code: "AL", name: "Alabama"),
        BiometricJurisdictionOption(code: "AK", name: "Alaska"),
        BiometricJurisdictionOption(code: "AZ", name: "Arizona"),
        BiometricJurisdictionOption(code: "AR", name: "Arkansas"),
        BiometricJurisdictionOption(code: "CA", name: "California"),
        BiometricJurisdictionOption(code: "CO", name: "Colorado"),
        BiometricJurisdictionOption(code: "CT", name: "Connecticut"),
        BiometricJurisdictionOption(code: "DE", name: "Delaware"),
        BiometricJurisdictionOption(code: "DC", name: "District of Columbia"),
        BiometricJurisdictionOption(code: "FL", name: "Florida"),
        BiometricJurisdictionOption(code: "GA", name: "Georgia"),
        BiometricJurisdictionOption(code: "HI", name: "Hawaii"),
        BiometricJurisdictionOption(code: "ID", name: "Idaho"),
        BiometricJurisdictionOption(code: "IL", name: "Illinois"),
        BiometricJurisdictionOption(code: "IN", name: "Indiana"),
        BiometricJurisdictionOption(code: "IA", name: "Iowa"),
        BiometricJurisdictionOption(code: "KS", name: "Kansas"),
        BiometricJurisdictionOption(code: "KY", name: "Kentucky"),
        BiometricJurisdictionOption(code: "LA", name: "Louisiana"),
        BiometricJurisdictionOption(code: "ME", name: "Maine"),
        BiometricJurisdictionOption(code: "MD", name: "Maryland"),
        BiometricJurisdictionOption(code: "MA", name: "Massachusetts"),
        BiometricJurisdictionOption(code: "MI", name: "Michigan"),
        BiometricJurisdictionOption(code: "MN", name: "Minnesota"),
        BiometricJurisdictionOption(code: "MS", name: "Mississippi"),
        BiometricJurisdictionOption(code: "MO", name: "Missouri"),
        BiometricJurisdictionOption(code: "MT", name: "Montana"),
        BiometricJurisdictionOption(code: "NE", name: "Nebraska"),
        BiometricJurisdictionOption(code: "NV", name: "Nevada"),
        BiometricJurisdictionOption(code: "NH", name: "New Hampshire"),
        BiometricJurisdictionOption(code: "NJ", name: "New Jersey"),
        BiometricJurisdictionOption(code: "NM", name: "New Mexico"),
        BiometricJurisdictionOption(code: "NY", name: "New York"),
        BiometricJurisdictionOption(code: "NC", name: "North Carolina"),
        BiometricJurisdictionOption(code: "ND", name: "North Dakota"),
        BiometricJurisdictionOption(code: "OH", name: "Ohio"),
        BiometricJurisdictionOption(code: "OK", name: "Oklahoma"),
        BiometricJurisdictionOption(code: "OR", name: "Oregon"),
        BiometricJurisdictionOption(code: "PA", name: "Pennsylvania"),
        BiometricJurisdictionOption(code: "RI", name: "Rhode Island"),
        BiometricJurisdictionOption(code: "SC", name: "South Carolina"),
        BiometricJurisdictionOption(code: "SD", name: "South Dakota"),
        BiometricJurisdictionOption(code: "TN", name: "Tennessee"),
        BiometricJurisdictionOption(code: "TX", name: "Texas"),
        BiometricJurisdictionOption(code: "UT", name: "Utah"),
        BiometricJurisdictionOption(code: "VT", name: "Vermont"),
        BiometricJurisdictionOption(code: "VA", name: "Virginia"),
        BiometricJurisdictionOption(code: "WA", name: "Washington"),
        BiometricJurisdictionOption(code: "WV", name: "West Virginia"),
        BiometricJurisdictionOption(code: "WI", name: "Wisconsin"),
        BiometricJurisdictionOption(code: "WY", name: "Wyoming"),
        BiometricJurisdictionOption(code: "AS", name: "American Samoa"),
        BiometricJurisdictionOption(code: "GU", name: "Guam"),
        BiometricJurisdictionOption(code: "MP", name: "Northern Mariana Islands"),
        BiometricJurisdictionOption(code: "PR", name: "Puerto Rico"),
        BiometricJurisdictionOption(code: "VI", name: "U.S. Virgin Islands")
    ]

    public static func subdivisions(for countryCode: String) -> [BiometricJurisdictionOption] {
        switch countryCode.uppercased() {
        case "CA": return canada
        case "US": return unitedStates
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
    /// v4 adds server-enforced consent, jurisdiction gating, a versioned
    /// disclosure hash, stronger consent evidence, and a 12-month inactivity
    /// expiry for both consent and account-level face templates.
    public static let currentPolicyVersion = 4
    public static let currentDisclosureId = "biometric-consent-v4"
    public static let currentDisclosureSHA256 = "23259c73e44fdb2f335a01a53cd6800947d204a5495731580b8c010917b4eab6"
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
