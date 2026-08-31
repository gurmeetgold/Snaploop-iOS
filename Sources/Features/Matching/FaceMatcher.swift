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
    /// Aggregate-only diagnostics for a single image. These counters intentionally
    /// contain no user IDs, template IDs, embeddings, image identifiers, scores,
    /// names or phone numbers, so scanner troubleshooting cannot turn into a
    /// biometric/identity log. They are safe to emit to local unified logging.
    public struct Diagnostics: Equatable, Sendable {
        public let detectedFaceCount: Int
        public let sizeRejectedFaceCount: Int
        public let eligibleFaceCount: Int
        public let acceptedFaceCount: Int
        public let belowThresholdFaceCount: Int
        public let ambiguityRejectedFaceCount: Int
        public let rosterCount: Int
        public let matchableParticipantCount: Int
    }

    public struct AppearanceResult: Equatable, Sendable {
        public let appearances: [PhotoMatch.Appearance]
        public let diagnostics: Diagnostics
    }

    public struct ParticipantScore: Equatable, Sendable {
        public let participantUserId: String
        public let recipientMembershipId: String?
        public let faceIdentityId: String
        public let faceProfileRevision: String
        public let bestTemplate: Double
        public let secondTemplate: Double?
        public let decisionScore: Double
        public let hasTemplateSupport: Bool
        public let isStrongSingle: Bool

        public var isAccepted: Bool { hasTemplateSupport || isStrongSingle }
    }

    private enum Assignment {
        case accepted(ParticipantScore)
        case belowThreshold
        case ambiguous
    }

    public let config: RemoteConfigValues
    public init(config: RemoteConfigValues) { self.config = config }

    /// Compatibility surface used by existing callers. Matching behavior is
    /// unchanged; the diagnostic-returning overload below powers safe scanner
    /// observability without requiring identity-bearing logs.
    public func appearances(in faces: [DetectedFace], participants: [EventParticipant]) -> [PhotoMatch.Appearance] {
        appearancesWithDiagnostics(in: faces, participants: participants).appearances
    }

    public func appearancesWithDiagnostics(
        in faces: [DetectedFace],
        participants: [EventParticipant]
    ) -> AppearanceResult {
        let matchableParticipantCount = participants.filter { isMatchable($0) }.count
        guard !faces.isEmpty else {
            return AppearanceResult(
                appearances: [],
                diagnostics: Diagnostics(
                    detectedFaceCount: 0,
                    sizeRejectedFaceCount: 0,
                    eligibleFaceCount: 0,
                    acceptedFaceCount: 0,
                    belowThresholdFaceCount: 0,
                    ambiguityRejectedFaceCount: 0,
                    rosterCount: participants.count,
                    matchableParticipantCount: matchableParticipantCount
                )
            )
        }

        var bestByParticipant: [String: (
            confidence: Double,
            membershipId: String?,
            identityId: String,
            revision: String
        )] = [:]
        var sizeRejectedFaceCount = 0
        var eligibleFaceCount = 0
        var acceptedFaceCount = 0
        var belowThresholdFaceCount = 0
        var ambiguityRejectedFaceCount = 0

        for face in faces {
            guard face.sizeFraction >= config.minFaceSizeFraction else {
                sizeRejectedFaceCount += 1
                continue
            }
            eligibleFaceCount += 1

            switch assignment(face: face, to: participants) {
            case .accepted(let winner):
                acceptedFaceCount += 1
                let existing = bestByParticipant[winner.participantUserId]
                if existing == nil || winner.decisionScore > existing!.confidence {
                    bestByParticipant[winner.participantUserId] = (
                        winner.decisionScore,
                        winner.recipientMembershipId,
                        winner.faceIdentityId,
                        winner.faceProfileRevision
                    )
                }
            case .belowThreshold:
                belowThresholdFaceCount += 1
            case .ambiguous:
                ambiguityRejectedFaceCount += 1
            }
        }

        let appearances = bestByParticipant.map {
            PhotoMatch.Appearance(
                participantUserId: $0.key,
                recipientMembershipId: $0.value.membershipId,
                confidence: $0.value.confidence,
                faceIdentityId: $0.value.identityId,
                faceProfileRevision: $0.value.revision
            )
        }.sorted { $0.confidence > $1.confidence }

        return AppearanceResult(
            appearances: appearances,
            diagnostics: Diagnostics(
                detectedFaceCount: faces.count,
                sizeRejectedFaceCount: sizeRejectedFaceCount,
                eligibleFaceCount: eligibleFaceCount,
                acceptedFaceCount: acceptedFaceCount,
                belowThresholdFaceCount: belowThresholdFaceCount,
                ambiguityRejectedFaceCount: ambiguityRejectedFaceCount,
                rosterCount: participants.count,
                matchableParticipantCount: matchableParticipantCount
            )
        )
    }

    private func isMatchable(_ participant: EventParticipant) -> Bool {
        participant.faceProfileVersion == FaceModelPolicy.currentVersion
            && !participant.stableFaceIdentityId.isEmpty
            && !participant.faceProfileRevision.isEmpty
    }

    private func participantScore(face: DetectedFace, participant: EventParticipant) -> ParticipantScore? {
        guard isMatchable(participant) else { return nil }

        let scores = participant.effectiveEmbeddings.compactMap {
            face.embedding.cosineSimilarity(to: $0)
        }
        guard let evaluation = FaceTemplateMatchPolicy.evaluate(
            similarities: scores,
            threshold: config.matchConfidenceThreshold
        ) else { return nil }

        return ParticipantScore(
            participantUserId: participant.userId,
            recipientMembershipId: participant.membershipId,
            faceIdentityId: participant.stableFaceIdentityId,
            faceProfileRevision: participant.faceProfileRevision,
            bestTemplate: evaluation.bestTemplate,
            secondTemplate: evaluation.secondTemplate,
            decisionScore: evaluation.decisionScore,
            hasTemplateSupport: evaluation.isCorroborated,
            isStrongSingle: evaluation.isStrongSingle
        )
    }

    private func assignment(face: DetectedFace, to participants: [EventParticipant]) -> Assignment {
        let ranked = participants.compactMap { participantScore(face: face, participant: $0) }
            .sorted { $0.decisionScore > $1.decisionScore }
        guard let winner = ranked.first, winner.isAccepted else { return .belowThreshold }

        if ranked.count > 1 {
            guard winner.decisionScore - ranked[1].decisionScore >= config.matchAmbiguityMargin else {
                return .ambiguous
            }
        }
        return .accepted(winner)
    }
}
