import Foundation

/// Pure, deterministic face matcher. Given the faces detected in a single photo
/// and the event roster, it decides which participants appear in that photo.
///
/// Design bias: **precision over recall.** Two guards enforce this:
///   1. A face must clear `matchConfidenceThreshold` similarity, and
///   2. The best-matching participant must beat the second-best by at least
///      `matchAmbiguityMargin`. A face that is nearly equidistant between two
///      people (classic look-alike / sibling case) is assigned to *nobody*.
///
/// No Vision, Core ML, or I/O here — this is a value transform over embeddings,
/// which is exactly what makes it exhaustively testable.
public struct FaceMatcher {

    public let config: RemoteConfigValues

    public init(config: RemoteConfigValues) {
        self.config = config
    }

    /// Which participants appear in a photo, given its detected faces.
    ///
    /// - Returns: One `Appearance` per matched participant, each carrying the
    ///   highest similarity among that participant's winning faces, sorted by
    ///   confidence descending. Empty if nobody clears the bar.
    public func appearances(
        in faces: [DetectedFace],
        participants: [EventParticipant]
    ) -> [PhotoMatch.Appearance] {
        guard !faces.isEmpty, !participants.isEmpty else { return [] }

        // Best confidence achieved per participant across all qualifying faces.
        var bestConfidence: [String: Double] = [:]

        for face in faces {
            // Precision guard #0: ignore tiny background faces.
            guard face.sizeFraction >= config.minFaceSizeFraction else { continue }

            guard let winner = assign(face: face, to: participants) else { continue }

            let existing = bestConfidence[winner.participantUserId]
            if existing == nil || winner.confidence > existing! {
                bestConfidence[winner.participantUserId] = winner.confidence
            }
        }

        return bestConfidence
            .map { PhotoMatch.Appearance(participantUserId: $0.key, confidence: $0.value) }
            .sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Single-face assignment

    private struct Assignment {
        let participantUserId: String
        let confidence: Double
    }

    /// Assigns one face to at most one participant, applying both precision
    /// guards. Returns `nil` when the face is below threshold or too ambiguous.
    private func assign(face: DetectedFace, to participants: [EventParticipant]) -> Assignment? {
        var best: (id: String, sim: Double)?
        var secondBestSim: Double = -1

        for participant in participants {
            // Dimension mismatch (e.g. an embedding from an older model
            // version) can't be compared — treat as a non-match rather than
            // guessing. Favors precision.
            guard let sim = face.embedding.cosineSimilarity(to: participant.faceEmbedding) else { continue }

            if best == nil || sim > best!.sim {
                secondBestSim = best?.sim ?? secondBestSim
                best = (participant.userId, sim)
            } else if sim > secondBestSim {
                secondBestSim = sim
            }
        }

        guard let winner = best else { return nil }

        // Guard #1: absolute confidence.
        guard winner.sim >= config.matchConfidenceThreshold else { return nil }

        // Guard #2: ambiguity margin. Only applies when there's a runner-up.
        if secondBestSim >= 0, (winner.sim - secondBestSim) < config.matchAmbiguityMargin {
            return nil
        }

        return Assignment(participantUserId: winner.id, confidence: winner.sim)
    }
}
