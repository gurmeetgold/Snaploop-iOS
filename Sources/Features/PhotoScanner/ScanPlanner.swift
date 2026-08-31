import Foundation

/// Legacy pre-Change-4 planner retained for migration/regression tests.
///
/// It models the old photo-level `scannedAssetIds` behavior and is intentionally
/// **not** used by the live `CameraSyncCoordinator`. The live scanner now uses a
/// protected photo corpus plus per-recipient cursors, because a photo that was
/// processed once can still need matching when Event membership or Face Setup
/// changes.
///
/// This compatibility planner still enforces the original pure planning rules:
///   • Only assets whose capture date falls inside the Event window.
///   • Skip assets recorded in the legacy scanned set.
///   • Never more than `maxAssetsPerSyncBatch` per pass.
///   • Deterministic order (oldest first) for stable regression coverage.
public struct ScanPlanner {

    public let config: RemoteConfigValues

    public init(config: RemoteConfigValues) {
        self.config = config
    }

    public struct Plan: Equatable, Sendable {
        /// Assets selected by the legacy planner for this pass.
        public let toScan: [PhotoAsset]
        /// How many eligible assets remain beyond this batch's cap.
        public let remaining: Int
        /// How many eligible assets were skipped by the legacy scanned set.
        public let alreadyScanned: Int

        public var isEmpty: Bool { toScan.isEmpty }
        public var hasMore: Bool { remaining > 0 }
    }

    /// Builds a legacy scan plan. Do not use this method to decide whether a
    /// current Event recipient needs matching; use Change-4 recipient cursors.
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
