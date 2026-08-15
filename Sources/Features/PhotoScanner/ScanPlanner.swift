import Foundation

/// Pure planner that decides **exactly which assets a sync pass should scan**.
///
/// It enforces the product's scanning rules without touching PhotoKit:
///   • Only assets whose capture date falls inside the event window.
///   • Never an asset already recorded in `ScanState` (incremental — no rescans).
///   • Never more than `maxAssetsPerSyncBatch` per pass; the remainder is
///     reported so the UI can say "more to sync" and the next pass continues.
///   • Deterministic order (oldest first) so batching is stable across passes.
///
/// The device only ever passes in its *own* library here — this planner has no
/// concept of another user's assets, by construction.
public struct ScanPlanner {

    public let config: RemoteConfigValues

    public init(config: RemoteConfigValues) {
        self.config = config
    }

    public struct Plan: Equatable, Sendable {
        /// Assets to scan in this pass (already filtered, deduped, capped, ordered).
        public let toScan: [PhotoAsset]
        /// How many eligible assets remain beyond this batch's cap.
        public let remaining: Int
        /// How many eligible assets were skipped because already scanned.
        public let alreadyScanned: Int

        public var isEmpty: Bool { toScan.isEmpty }
        public var hasMore: Bool { remaining > 0 }
    }

    /// Builds a scan plan.
    ///
    /// - Parameters:
    ///   - assets: The device's own library assets (any order).
    ///   - event: The event whose date window scopes the scan.
    ///   - state: What has already been scanned for this event on this device.
    public func plan(assets: [PhotoAsset], event: Event, state: ScanState) -> Plan {
        let range = event.dateRange

        // Eligible = in window, oldest first, stable tie-break by id.
        let eligible = assets
            .filter { range.contains($0.creationDate) }
            .sorted {
                $0.creationDate != $1.creationDate
                    ? $0.creationDate < $1.creationDate
                    : $0.id < $1.id
            }

        let fresh = eligible.filter { !state.hasScanned($0.id) }
        let alreadyScanned = eligible.count - fresh.count

        let cap = max(0, config.maxAssetsPerSyncBatch)
        let batch = Array(fresh.prefix(cap))
        let remaining = fresh.count - batch.count

        return Plan(toScan: batch, remaining: remaining, alreadyScanned: alreadyScanned)
    }
}
