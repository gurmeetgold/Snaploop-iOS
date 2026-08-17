import Foundation

/// Precision-first multi-template face matcher.
///
/// v3 changes recognition from "one reference selfie vs one detected face" to a
/// small template ensemble per participant. A candidate must:
///
/// 1. clear the absolute threshold,
/// 2. have enough support across that participant's templates, and
/// 3. beat the second-best participant by the ambiguity margin.
///
/// This deliberately prefers "I don't know" over exposing a photo to the wrong
/// person.
public struct FaceMatcher {

    public let config: RemoteConfigValues

    public init(
        config: RemoteConfigValues
    ) {
        self.config = config
    }

    public func appearances(
        in faces: [DetectedFace],
        participants: [EventParticipant]
    ) -> [PhotoMatch.Appearance] {
        guard
            !faces.isEmpty,
            !participants.isEmpty
        else {
            return []
        }

        var bestConfidence: [String: Double] = [:]

        for face in faces {
            guard
                face.sizeFraction
                    >= config.minFaceSizeFraction
            else {
                continue
            }

            guard let winner = assign(
                face: face,
                to: participants
            ) else {
                continue
            }

            let existing =
                bestConfidence[winner.participantUserId]

            if existing == nil
                || winner.confidence > existing! {
                bestConfidence[
                    winner.participantUserId
                ] = winner.confidence
            }
        }

        return bestConfidence
            .map {
                PhotoMatch.Appearance(
                    participantUserId: $0.key,
                    confidence: $0.value
                )
            }
            .sorted {
                $0.confidence > $1.confidence
            }
    }

    private struct Assignment {
        let participantUserId: String
        let confidence: Double
    }

    /// Participant-level score from a detected face against multiple enrolled
    /// templates.
    ///
    /// We do not use a simple max. A single lucky template can be noisy.
    /// Instead the score blends the best result with support from the next
    /// strongest templates.
    private func score(
        face: DetectedFace,
        participant: EventParticipant
    ) -> Double? {
        let similarities = participant.effectiveEmbeddings
            .compactMap {
                face.embedding.cosineSimilarity(to: $0)
            }
            .sorted(by: >)

        guard let best = similarities.first else {
            return nil
        }

        // Old/single-template profiles still work during migration.
        guard similarities.count >= 2 else {
            return best
        }

        let second = similarities[1]

        if similarities.count >= 3 {
            let third = similarities[2]

            // Best template remains dominant, while second/third template
            // agreement makes pose-specific lucky matches less influential.
            return (
                (best * 0.60)
                + (second * 0.27)
                + (third * 0.13)
            )
        }

        return (
            (best * 0.72)
            + (second * 0.28)
        )
    }

    private func assign(
        face: DetectedFace,
        to participants: [EventParticipant]
    ) -> Assignment? {
        var ranked: [(id: String, score: Double)] = []

        for participant in participants {
            guard let score = score(
                face: face,
                participant: participant
            ) else {
                continue
            }

            ranked.append(
                (participant.userId, score)
            )
        }

        ranked.sort {
            $0.score > $1.score
        }

        guard let winner = ranked.first else {
            return nil
        }

        guard
            winner.score
                >= config.matchConfidenceThreshold
        else {
            return nil
        }

        if ranked.count > 1 {
            let runnerUp = ranked[1]

            guard
                (winner.score - runnerUp.score)
                    >= config.matchAmbiguityMargin
            else {
                return nil
            }
        }

        return Assignment(
            participantUserId: winner.id,
            confidence: winner.score
        )
    }
}
