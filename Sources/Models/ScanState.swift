import Foundation

/// Per-event, per-device record of what the scanner has already processed, so a
/// sync pass never rescans an asset it has already seen. This is what makes
/// "Sync My Camera" incremental instead of a full re-scan every time.
///
/// Persisted locally (the device only ever scans its own library). Keyed by
/// event because the same photo can belong to two overlapping events with
/// different rosters.
public struct ScanState: Equatable, Codable, Sendable {
    public let eventId: String

    /// PhotoKit local identifiers already scanned in this event. Membership here
    /// is the single source of truth for "already handled — skip it".
    public private(set) var scannedAssetIds: Set<String>

    /// Timestamp of the most recent completed pass (for UI: "Last synced …").
    public var lastSyncedAt: Date?

    public init(
        eventId: String,
        scannedAssetIds: Set<String> = [],
        lastSyncedAt: Date? = nil
    ) {
        self.eventId = eventId
        self.scannedAssetIds = scannedAssetIds
        self.lastSyncedAt = lastSyncedAt
    }

    public func hasScanned(_ assetId: String) -> Bool {
        scannedAssetIds.contains(assetId)
    }

    /// Records a batch of asset ids as scanned. Idempotent.
    public mutating func markScanned(_ ids: some Sequence<String>) {
        scannedAssetIds.formUnion(ids)
    }

    /// Removes identifiers that are no longer present in the event's current
    /// PhotoKit date-window result. This prevents deleted photos and stale
    /// limited-library identifiers from growing persisted scan state forever.
    public mutating func retainScannedAssetIds(_ validIds: Set<String>) {
        scannedAssetIds.formIntersection(validIds)
    }

    public var scannedCount: Int { scannedAssetIds.count }
}
