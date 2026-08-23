import Foundation

/// One identity-level decision made from a query face against the enrollment
/// templates for a single person. Keeping this policy separate lets the Face
/// Test screen exercise the exact same acceptance rule as camera matching.
public struct FaceTemplateMatchEvaluation: Equatable, Sendable {
    public let bestTemplate: Double
    public let secondTemplate: Double?
    public let decisionScore: Double
    public let isCorroborated: Bool
    public let isStrongSingle: Bool

    public var isAccepted: Bool { isCorroborated || isStrongSingle }
}

public enum FaceTemplateMatchPolicy {
    public static func evaluate(similarities: [Double], threshold: Double) -> FaceTemplateMatchEvaluation? {
        let scores = similarities.sorted(by: >)
        guard let best = scores.first else { return nil }
        let second = scores.count > 1 ? scores[1] : nil

        let corroboratedBestFloor = threshold - FaceModelPolicy.corroboratedBestTemplateSlack
        let supportingFloor = threshold - FaceModelPolicy.supportingTemplateSlack
        let corroborated = best >= corroboratedBestFloor
            && (second.map { $0 >= supportingFloor } ?? false)
        let strongSingle = best >= threshold + FaceModelPolicy.strongSingleTemplateBonus

        // Only blend the runner-up when it independently supports the identity.
        // This avoids pulling a strong pose-specific hit down with an unrelated
        // side/tilt template while still rewarding agreement across enrollment
        // poses in the near-threshold band.
        let decision: Double
        if let second, corroborated {
            decision = best * 0.90 + second * 0.10
        } else {
            decision = best
        }

        return FaceTemplateMatchEvaluation(
            bestTemplate: best,
            secondTemplate: second,
            decisionScore: decision,
            isCorroborated: corroborated,
            isStrongSingle: strongSingle
        )
    }
}

/// Precision-first v5 identity matcher.
public struct FaceMatcher {
    public struct ParticipantScore: Equatable, Sendable {
        public let participantUserId: String
        public let bestTemplate: Double
        public let secondTemplate: Double?
        public let decisionScore: Double
        public let hasTemplateSupport: Bool
        public let isStrongSingle: Bool

        public var isAccepted: Bool { hasTemplateSupport || isStrongSingle }
    }

    public let config: RemoteConfigValues
    public init(config: RemoteConfigValues) { self.config = config }

    public func appearances(in faces: [DetectedFace], participants: [EventParticipant]) -> [PhotoMatch.Appearance] {
        guard !faces.isEmpty, !participants.isEmpty else { return [] }
        var bestConfidence: [String: Double] = [:]

        for face in faces {
            guard face.sizeFraction >= config.minFaceSizeFraction else { continue }
            guard let winner = assign(face: face, to: participants) else { continue }
            let existing = bestConfidence[winner.participantUserId]
            if existing == nil || winner.decisionScore > existing! {
                bestConfidence[winner.participantUserId] = winner.decisionScore
            }
        }

        return bestConfidence.map {
            PhotoMatch.Appearance(participantUserId: $0.key, confidence: $0.value)
        }.sorted { $0.confidence > $1.confidence }
    }

    private func participantScore(face: DetectedFace, participant: EventParticipant) -> ParticipantScore? {
        guard participant.faceProfileVersion == FaceModelPolicy.currentVersion else { return nil }

        // Rank templates by how well they match this particular face. This is
        // deliberately pose-adaptive: a frontal gallery photo should not be
        // dragged down by the enrollee's weakest side/tilt template, and vice
        // versa. Near the operating threshold, two enrollment poses must agree.
        let scores = participant.effectiveEmbeddings.compactMap {
            face.embedding.cosineSimilarity(to: $0)
        }
        guard let evaluation = FaceTemplateMatchPolicy.evaluate(
            similarities: scores,
            threshold: config.matchConfidenceThreshold
        ) else { return nil }

        return ParticipantScore(
            participantUserId: participant.userId,
            bestTemplate: evaluation.bestTemplate,
            secondTemplate: evaluation.secondTemplate,
            decisionScore: evaluation.decisionScore,
            hasTemplateSupport: evaluation.isCorroborated,
            isStrongSingle: evaluation.isStrongSingle
        )
    }

    private func assign(face: DetectedFace, to participants: [EventParticipant]) -> ParticipantScore? {
        let ranked = participants.compactMap { participantScore(face: face, participant: $0) }
            .sorted { $0.decisionScore > $1.decisionScore }
        guard let winner = ranked.first, winner.isAccepted else { return nil }

        if ranked.count > 1 {
            guard winner.decisionScore - ranked[1].decisionScore >= config.matchAmbiguityMargin else { return nil }
        }
        return winner
    }
}
