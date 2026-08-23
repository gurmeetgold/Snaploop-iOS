import Foundation

/// A narrow, auditable record of consent for SnapLoop face matching.
///
/// This record does not contain biometric data. It records only that the user
/// explicitly agreed to the described purpose/version at a specific time.
public struct BiometricConsentRecord: Equatable, Codable, Sendable {
    /// v3 makes the biometric processing terms more explicit: face-template
    /// creation and cloud storage, Event-scoped delivery to participating
    /// devices for on-device matching, retention, withdrawal consequences,
    /// purpose limitation, and the 18+ requirement for Face Match.
    /// Existing consent must not silently cover a materially expanded notice.
    public static let currentPolicyVersion = 3

    public let userId: String
    public let policyVersion: Int
    public let acceptedAt: Date
    public var withdrawnAt: Date?

    public init(
        userId: String,
        policyVersion: Int = Self.currentPolicyVersion,
        acceptedAt: Date,
        withdrawnAt: Date? = nil
    ) {
        self.userId = userId
        self.policyVersion = policyVersion
        self.acceptedAt = acceptedAt
        self.withdrawnAt = withdrawnAt
    }

    public var isActive: Bool {
        policyVersion == Self.currentPolicyVersion
            && withdrawnAt == nil
    }
}
