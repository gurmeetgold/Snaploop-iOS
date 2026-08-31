import FirebaseFunctions
import Foundation

/// Retrieves the minimum biometric matching set through a trusted callable.
/// Firestore participant roster documents no longer expose face embeddings.
enum EventFaceProfileClient {
    @MainActor
    static func list(eventId: String) async throws -> [EventParticipant] {
        // Membership generation is fetched independently from the non-biometric
        // member directory. Failure of this additive migration lookup must not
        // break existing face matching; pre-migration participants remain valid
        // with membershipId == nil until a later reconciliation succeeds.
        async let membershipIdsTask = loadMembershipIds(eventId: eventId)

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

        let membershipIds = (try? await membershipIdsTask) ?? [:]
        return try rows.map { row in
            let userId = row["userId"] as? String
            return try Self.decode(row, membershipId: userId.flatMap { membershipIds[$0] })
        }
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
                  let rawMembershipId = row["membershipId"] as? String else { continue }
            let membershipId = rawMembershipId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !membershipId.isEmpty else { continue }
            result[userId] = membershipId
        }
        return result
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
