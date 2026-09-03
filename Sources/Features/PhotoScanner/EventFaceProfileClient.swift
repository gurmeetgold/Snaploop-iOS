import FirebaseAuth
import FirebaseFunctions
import Foundation

struct EventFaceProfileManifest: Sendable {
    let participants: [EventParticipant]
    let sourceMembershipId: String?
}

/// Retrieves the minimum biometric matching set through a trusted callable.
/// Firestore participant roster documents no longer expose face embeddings.
enum EventFaceProfileClient {
    @MainActor
    static func manifest(eventId: String) async throws -> EventFaceProfileManifest {
        let raw: Any = try await withCheckedThrowingContinuation { continuation in
            Functions.functions().httpsCallable("listEventFaceProfiles").call([
                "eventId": eventId
            ]) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result?.data as Any)
            }
        }

        guard let wrapper = raw as? [String: Any],
              let rows = wrapper["participants"] as? [[String: Any]] else {
            throw AppError.decoding("Event face profile response is malformed")
        }

        // Change 4 requires the same server revision that returns authoritative
        // membership generations with the biometric roster. The Release device
        // test used to deploy only a subset of Functions, leaving this callable
        // stale while the iOS client had already moved to source-scoped matching.
        // Fail before scanning rather than letting every positive publication fail
        // asset-by-asset and masquerade as another scan batch.
        let backendSourceMembershipId = normalizedMembershipId(wrapper["callerMembershipId"])
        let hasLegacyRosterRows = rows.contains {
            normalizedMembershipId($0["membershipId"]) == nil
        }
        if AppEnvironment.useLiveServices,
           (backendSourceMembershipId == nil || hasLegacyRosterRows) {
            throw AppError.matchingServiceOutdated
        }

        // Compatibility fallback is retained for non-live/test callers and old
        // fixtures. A production Release build must pass the contract check above.
        let requiresLegacyMembershipLookup = hasLegacyRosterRows
        let currentUserId = Auth.auth().currentUser?.uid
        let needsSourceFallback = backendSourceMembershipId == nil && currentUserId != nil
        let legacyMembershipIds = (requiresLegacyMembershipLookup || needsSourceFallback)
            ? ((try? await loadMembershipIds(eventId: eventId)) ?? [:])
            : [:]

        let participants = try rows.map { row in
            let userId = row["userId"] as? String
            let membershipId = normalizedMembershipId(row["membershipId"])
                ?? userId.flatMap { legacyMembershipIds[$0] }
            return try Self.decode(row, membershipId: membershipId)
        }
        let sourceMembershipId = backendSourceMembershipId
            ?? currentUserId.flatMap { legacyMembershipIds[$0] }

        return EventFaceProfileManifest(
            participants: participants,
            sourceMembershipId: sourceMembershipId
        )
    }

    /// Compatibility surface used by existing scan callers. If the source user
    /// is still an Event member but no longer has an active/matchable Face Setup,
    /// append a deliberately non-matchable membership carrier. The coordinator
    /// needs the source membership generation for the publication commit barrier,
    /// but FaceMatcher will ignore this row because its face profile version and
    /// identity are intentionally invalid for matching.
    @MainActor
    static func list(eventId: String) async throws -> [EventParticipant] {
        let manifest = try await manifest(eventId: eventId)
        var participants = manifest.participants

        if let userId = Auth.auth().currentUser?.uid,
           participants.first(where: { $0.userId == userId }) == nil,
           let sourceMembershipId = manifest.sourceMembershipId {
            participants.append(EventParticipant(
                userId: userId,
                membershipId: sourceMembershipId,
                displayName: nil,
                faceIdentityId: nil,
                faceEmbedding: FaceEmbedding(normalized: [1]),
                faceTemplates: [],
                faceProfileVersion: 0,
                joinedAt: .distantPast
            ))
        }

        return participants
    }

    @MainActor
    private static func loadMembershipIds(eventId: String) async throws -> [String: String] {
        let raw: Any = try await withCheckedThrowingContinuation { continuation in
            Functions.functions().httpsCallable("listEventMembers").call([
                "eventId": eventId
            ]) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result?.data as Any)
            }
        }

        guard let wrapper = raw as? [String: Any],
              let rows = wrapper["members"] as? [[String: Any]] else {
            throw AppError.decoding("Event member response is malformed")
        }

        var result: [String: String] = [:]
        for row in rows {
            guard let userId = row["userId"] as? String,
                  let membershipId = normalizedMembershipId(row["membershipId"]) else { continue }
            result[userId] = membershipId
        }
        return result
    }

    private static func normalizedMembershipId(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decode(_ data: [String: Any], membershipId: String?) throws -> EventParticipant {
        let vector: [Float]
        if let numbers = data["faceEmbedding"] as? [NSNumber] {
            vector = numbers.map(\.floatValue)
        } else if let doubles = data["faceEmbedding"] as? [Double] {
            vector = doubles.map(Float.init)
        } else {
            throw AppError.decoding("Event participant face template is missing")
        }

        guard let userId = data["userId"] as? String, !vector.isEmpty,
              let faceIdentityId = data["faceIdentityId"] as? String,
              !faceIdentityId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.decoding("Event participant identity is missing")
        }

        let joinedMillis = (data["joinedAtMillis"] as? NSNumber)?.doubleValue
            ?? data["joinedAtMillis"] as? Double
            ?? Date().timeIntervalSince1970 * 1000
        let joinedAt = Date(timeIntervalSince1970: joinedMillis / 1000)

        let templates: [FaceTemplate] = (data["faceTemplates"] as? [[String: Any]] ?? []).compactMap { item in
            let rawVector: [Float]
            if let numbers = item["embedding"] as? [NSNumber] {
                rawVector = numbers.map(\.floatValue)
            } else if let doubles = item["embedding"] as? [Double] {
                rawVector = doubles.map(Float.init)
            } else {
                return nil
            }

            guard let embedding = FaceEmbedding(rawVector),
                  let poseRaw = item["pose"] as? String,
                  let pose = FaceTemplate.Pose(rawValue: poseRaw) else {
                return nil
            }

            let createdAtMillis = (item["createdAtMillis"] as? NSNumber)?.doubleValue
                ?? item["createdAtMillis"] as? Double
            let createdAt = createdAtMillis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? joinedAt

            return FaceTemplate(
                id: item["id"] as? String ?? UUID().uuidString,
                embedding: embedding,
                pose: pose,
                quality: (item["quality"] as? NSNumber)?.doubleValue ?? item["quality"] as? Double ?? 1,
                createdAt: createdAt
            )
        }

        let version = (data["faceProfileVersion"] as? NSNumber)?.intValue
            ?? data["faceProfileVersion"] as? Int
            ?? 1

        return EventParticipant(
            userId: userId,
            membershipId: membershipId,
            displayName: data["displayName"] as? String,
            phoneNumber: nil,
            faceIdentityId: faceIdentityId,
            faceEmbedding: FaceEmbedding(normalized: vector),
            faceTemplates: templates,
            faceProfileVersion: version,
            joinedAt: joinedAt
        )
    }
}
