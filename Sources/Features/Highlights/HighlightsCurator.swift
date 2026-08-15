import Foundation

/// A curated highlight collection for an event: a group reel plus a personal
/// reel per participant. Static grid for the MVP (a video montage is a
/// fast-follow). Purely additive — nothing here touches the core sync/match loop.
public struct Highlights: Equatable, Sendable {
    public let eventId: String
    /// Best photos across the whole event (deduped, quality-ranked, time-diverse).
    public let group: [String]                         // photo ids
    /// Best photos of each participant, keyed by user id.
    public let perParticipant: [String: [String]]      // userId -> photo ids

    public init(eventId: String, group: [String], perParticipant: [String: [String]]) {
        self.eventId = eventId
        self.group = group
        self.perParticipant = perParticipant
    }

    public var isEmpty: Bool { group.isEmpty && perParticipant.allSatisfy { $0.value.isEmpty } }
}

/// Selects highlights from matched photos + quality signals. Deterministic and
/// pure. Favors quality, then spreads picks across time so a reel isn't five
/// near-identical frames from one minute.
public struct HighlightsCurator {
    public let groupLimit: Int
    public let perParticipantLimit: Int
    public let burstWindow: TimeInterval

    public init(groupLimit: Int = 12, perParticipantLimit: Int = 6, burstWindow: TimeInterval = 3) {
        self.groupLimit = groupLimit
        self.perParticipantLimit = perParticipantLimit
        self.burstWindow = burstWindow
    }

    public func curate(
        eventId: String,
        photos: [EventPhoto],
        quality: [String: PhotoQualitySignals]
    ) -> Highlights {
        // Collapse bursts to their best frame first (no near-duplicates in a reel).
        let deduped = BestShotSelector(burstWindow: burstWindow).bestShots(from: photos, quality: quality)

        let group = pickDiverse(deduped, quality: quality, limit: groupLimit)

        // Per participant: only photos they appear in.
        var perParticipant: [String: [String]] = [:]
        let allUsers = Set(deduped.flatMap(\.matchedUserIds))
        for user in allUsers {
            let theirs = deduped.filter { $0.matchedUserIds.contains(user) }
            perParticipant[user] = pickDiverse(theirs, quality: quality, limit: perParticipantLimit)
        }
        return Highlights(eventId: eventId, group: group, perParticipant: perParticipant)
    }

    /// Ranks by quality, then greedily fills the reel while spreading picks over
    /// the event's timeline (each new pick prefers the highest-quality photo
    /// that's furthest in time from what's already chosen).
    private func pickDiverse(
        _ photos: [EventPhoto],
        quality: [String: PhotoQualitySignals],
        limit: Int
    ) -> [String] {
        guard limit > 0, !photos.isEmpty else { return [] }
        func score(_ p: EventPhoto) -> Double { quality[p.id]?.score ?? 0 }

        let ranked = photos.sorted {
            let sa = score($0), sb = score($1)
            return sa != sb ? sa > sb : $0.capturedAt > $1.capturedAt
        }
        if ranked.count <= limit { return ranked.map(\.id) }

        var chosen: [EventPhoto] = [ranked[0]]   // always take the single best
        var pool = Array(ranked.dropFirst())

        while chosen.count < limit, !pool.isEmpty {
            // Pick the candidate maximizing (quality + temporal distance to the
            // nearest already-chosen photo), so the reel spans the event.
            let best = pool.enumerated().max { a, b in
                combinedScore(a.element, chosen: chosen, score: score)
                    < combinedScore(b.element, chosen: chosen, score: score)
            }!
            chosen.append(best.element)
            pool.remove(at: best.offset)
        }
        // Present chronologically.
        return chosen.sorted { $0.capturedAt < $1.capturedAt }.map(\.id)
    }

    private func combinedScore(
        _ p: EventPhoto, chosen: [EventPhoto], score: (EventPhoto) -> Double
    ) -> Double {
        let nearest = chosen.map { abs($0.capturedAt.timeIntervalSince(p.capturedAt)) }.min() ?? 0
        // Normalize temporal distance softly (hours) so it nudges, not dominates.
        let temporal = min(1, nearest / 3600)
        return 0.7 * score(p) + 0.3 * temporal
    }
}
