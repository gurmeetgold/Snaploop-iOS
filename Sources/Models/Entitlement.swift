import Foundation

/// Monetization tier. No paywall ships in the MVP — this exists so pricing can
/// be layered on later without a schema migration. Stored on the user (and
/// optionally overridden per-event by an event pass).
public enum Entitlement: String, Codable, CaseIterable, Sendable {
    case free
    case eventPass = "event_pass"
    case premiumIndividual = "premium_individual"
    case premiumOrganizer = "premium_organizer"
    case business

    /// Whether this tier unlocks a given premium capability. All false today;
    /// this is the single switchboard a future paywall flips.
    public func allows(_ capability: PremiumCapability) -> Bool {
        switch capability {
        case .videoHighlightReel, .unlimitedParticipants, .extendedRetention:
            return self == .premiumOrganizer || self == .business
        }
    }
}

public enum PremiumCapability: Sendable {
    case videoHighlightReel
    case unlimitedParticipants
    case extendedRetention
}
