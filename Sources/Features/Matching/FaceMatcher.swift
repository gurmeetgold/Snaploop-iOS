import Foundation

/// Precision-first v5 identity matcher.
public struct FaceMatcher {
    public struct ParticipantScore: Equatable, Sendable {
        public let participantUserId: String
        public let bestTemplate: Double
        public let secondTemplate: Double?
        public let decisionScore: Double
        public let hasTemplateSupport: Bool
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
        // versa. A second template is used only as corroborating evidence.
        let scores = participant.effectiveEmbeddings.compactMap {
            face.embedding.cosineSimilarity(to: $0)
        }.sorted(by: >)
        guard let best = scores.first else { return nil }

        let second = scores.count > 1 ? scores[1] : nil
        let supportFloor = config.matchConfidenceThreshold - FaceModelPolicy.supportingTemplateSlack
        let supported = second.map { $0 >= supportFloor } ?? false

        // Never average a clearly irrelevant template into a good pose-specific
        // match. If corroboration is present, give it a small precision bonus;
        // otherwise retain the best identity score and let strong-single +
        // participant ambiguity gates decide whether it is safe enough.
        let decision: Double
        if let second, supported {
            decision = best * 0.90 + second * 0.10
        } else {
            decision = best
        }

        return ParticipantScore(
            participantUserId: participant.userId,
            bestTemplate: best,
            secondTemplate: second,
            decisionScore: decision,
            hasTemplateSupport: supported
        )
    }

    private func assign(face: DetectedFace, to participants: [EventParticipant]) -> ParticipantScore? {
        let ranked = participants.compactMap { participantScore(face: face, participant: $0) }
            .sorted { $0.decisionScore > $1.decisionScore }
        guard let winner = ranked.first else { return nil }
        guard winner.bestTemplate >= config.matchConfidenceThreshold else { return nil }

        let strongSingle = winner.bestTemplate >= config.matchConfidenceThreshold + FaceModelPolicy.strongSingleTemplateBonus
        guard winner.hasTemplateSupport || strongSingle else { return nil }

        if ranked.count > 1 {
            guard winner.decisionScore - ranked[1].decisionScore >= config.matchAmbiguityMargin else { return nil }
        }
        return winner
    }
}
