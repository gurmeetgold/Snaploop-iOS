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

    /// The first public SnapLoop release is intentionally limited to India.
    /// Keeping this check narrow prevents an old/stale client value from
    /// accidentally enabling Face Match in another jurisdiction.
    public var isFaceMatchAvailable: Bool {
        countryCode == "IN" && subdivisionCode.isEmpty
    }
}

public enum BiometricJurisdictionCatalog {
    /// India is the only residence offered for the first public release.
    public static let countries = [
        BiometricJurisdictionOption(code: "IN", name: "India")
    ]

    public static func subdivisions(for countryCode: String) -> [BiometricJurisdictionOption] {
        []
    }

    public static func firstAvailableSubdivision(for countryCode: String) -> String {
        ""
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
    public let ownFaceAttested: Bool
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
        ownFaceAttested: Bool = true,
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
        self.ownFaceAttested = ownFaceAttested
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
            && ownFaceAttested
            && jurisdiction.isFaceMatchAvailable
    }
}