import Foundation

/// On-device quality signals for one photo. Computed by a `QualityScoring`
/// service (Vision sharpness / face quality) — kept as a plain value so all the
/// selection/curation logic below is pure and unit-testable.
public struct PhotoQualitySignals: Equatable, Sendable {
    public let photoId: String
    public let sharpness: Double     // 0...1, higher = crisper
    public let faceQuality: Double   // 0...1, best detected-face quality (open eyes, frontal)
    public let exposure: Double      // 0...1, 1 = well-exposed

    public init(photoId: String, sharpness: Double, faceQuality: Double, exposure: Double) {
        self.photoId = photoId
        self.sharpness = sharpness
        self.faceQuality = faceQuality
        self.exposure = exposure
    }

    /// Composite score used for ranking. Weighted toward sharpness + face
    /// quality (this is a people-photo product).
    public var score: Double {
        0.45 * sharpness + 0.40 * faceQuality + 0.15 * exposure
    }

    /// Whether the photo is unusably blurry and should be down-ranked/hidden by
    /// default (still accessible).
    public func isLikelyBlurry(threshold: Double) -> Bool {
        sharpness < threshold
    }
}

/// Produces quality signals for photos. Behind a protocol so the curation logic
/// never touches Vision directly. Production implementation runs on-device.
public protocol QualityScoring: Sendable {
    func signals(for photoIds: [String]) async -> [String: PhotoQualitySignals]
}

/// Groups burst/near-duplicate photos and picks the best of each. Pure.
public struct BestShotSelector {
    /// Photos taken by the same person within this many seconds are treated as
    /// one burst.
    public let burstWindow: TimeInterval
    public init(burstWindow: TimeInterval = 3) { self.burstWindow = burstWindow }

    /// Splits photos into bursts (same source, adjacent capture times).
    public func bursts(_ photos: [EventPhoto]) -> [[EventPhoto]] {
        let sorted = photos.sorted {
            $0.sourceUserId != $1.sourceUserId
                ? $0.sourceUserId < $1.sourceUserId
                : $0.capturedAt < $1.capturedAt
        }
        var groups: [[EventPhoto]] = []
        for photo in sorted {
            if let last = groups.last?.last,
               last.sourceUserId == photo.sourceUserId,
               photo.capturedAt.timeIntervalSince(last.capturedAt) <= burstWindow {
                groups[groups.count - 1].append(photo)
            } else {
                groups.append([photo])
            }
        }
        return groups
    }

    /// One representative (highest quality) photo per burst — the default grid
    /// view. Ties break on stable id so ordering is deterministic.
    public func bestShots(
        from photos: [EventPhoto],
        quality: [String: PhotoQualitySignals]
    ) -> [EventPhoto] {
        bursts(photos).compactMap { group in
            group.max { a, b in
                let sa = quality[a.id]?.score ?? 0
                let sb = quality[b.id]?.score ?? 0
                return sa != sb ? sa < sb : a.id > b.id
            }
        }
        .sorted { $0.capturedAt > $1.capturedAt }
    }
}

/// Partitions photos into "front and center" vs "down-ranked (blurry)".
public struct BlurFilter {
    public let threshold: Double
    public init(threshold: Double = 0.35) { self.threshold = threshold }

    public func partition(
        _ photos: [EventPhoto],
        quality: [String: PhotoQualitySignals]
    ) -> (shown: [EventPhoto], downRanked: [EventPhoto]) {
        var shown: [EventPhoto] = []
        var down: [EventPhoto] = []
        for p in photos {
            if let q = quality[p.id], q.isLikelyBlurry(threshold: threshold) { down.append(p) }
            else { shown.append(p) }
        }
        return (shown, down)
    }
}
