import Foundation
import FirebaseFirestore
import FirebaseFunctions
import FirebaseStorage

/// Live match metadata + thumbnail repository.
/// Originals remain device-local; signed original transfers are a later slice.
public final class FirebaseMatchRepository: MatchRepository, @unchecked Sendable {
    private let db: Firestore
    private let storage: Storage
    private let functions: Functions

    public init(
        db: Firestore = .firestore(),
        storage: Storage = .storage(),
        functions: Functions = .functions()
    ) {
        self.db = db
        self.storage = storage
        self.functions = functions
    }

    public func upload(match: PhotoMatch, thumbnailJPEG: Data) async throws {
        let docId = Self.documentId(for: match.id)
        let path = "events/\(match.eventId)/photos/\(match.ownerUserId)/\(docId)/thumbnail.jpg"
        let ref = storage.reference(withPath: path)

        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ref.putData(thumbnailJPEG, metadata: metadata) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }

        let appearances: [[String: Any]] = match.appearances.map {
            [
                "participantUserId": $0.participantUserId,
                "confidence": $0.confidence
            ]
        }

        let payload: [String: Any] = [
            "id": match.id,
            "eventId": match.eventId,
            "assetLocalId": match.assetLocalId,
            "appearances": appearances,
            "capturedAtMillis": Int64(match.capturedAt.timeIntervalSince1970 * 1000),
            "matchedAtMillis": Int64(match.matchedAt.timeIntervalSince1970 * 1000),
            "thumbnailPath": path
        ]

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                functions.httpsCallable("publishMatch").call(payload) { result, error in
                    if let error { continuation.resume(throwing: error); return }
                    continuation.resume(returning: result?.data as Any)
                }
            }
        } catch {
            // A failed trusted publish leaves no readable metadata document.
            // Remove the unreferenced thumbnail when possible.
            try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ref.delete { cleanupError in
                    if let cleanupError { continuation.resume(throwing: cleanupError) }
                    else { continuation.resume(returning: ()) }
                }
            }
            throw error
        }
    }

    public func dismissAppearance(matchId: String, participantUserId: String) async throws {
        guard let eventId = matchId.split(separator: ":", maxSplits: 1).first.map(String.init) else {
            throw AppError.decoding("match id missing event id")
        }

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            functions.httpsCallable("dismissAppearance").call([
                "eventId": eventId,
                "matchId": matchId,
                "participantUserId": participantUserId
            ]) { result, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: result?.data as Any)
            }
        }
    }

    public func myPhotos(eventId: String, userId: String) async throws -> [PhotoMatch] {
        let snap = try await db.collection("events")
            .document(eventId)
            .collection("photos")
            .whereField("matchedUserIds", arrayContains: userId)
            .getDocuments()

        return try snap.documents
            .map { try Self.decode(id: $0.documentID, data: $0.data()) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    public func sharedAlbum(eventId: String) async throws -> [PhotoMatch] {
        let snap = try await db.collection("events")
            .document(eventId)
            .collection("photos")
            .getDocuments()

        return try snap.documents
            .map { try Self.decode(id: $0.documentID, data: $0.data()) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    public func signedOriginalURL(match: PhotoMatch, ttlHours: Int) async throws -> URL {
        throw AppError.originalUnavailable
    }

    private static func documentId(for value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(id: String, data: [String: Any]) throws -> PhotoMatch {
        guard
            let matchId = data["id"] as? String,
            let eventId = data["eventId"] as? String,
            let sourceUserId = data["sourceUserId"] as? String,
            let assetLocalId = data["assetLocalId"] as? String,
            let capturedAt = (data["capturedAt"] as? Timestamp)?.dateValue(),
            let matchedAt = (data["matchedAt"] as? Timestamp)?.dateValue()
        else {
            throw AppError.decoding("photo \(id) missing required fields")
        }

        let raw = data["appearances"] as? [[String: Any]] ?? []
        let appearances = raw.compactMap { item -> PhotoMatch.Appearance? in
            guard let userId = item["participantUserId"] as? String else { return nil }
            let confidence = (item["confidence"] as? NSNumber)?.doubleValue
                ?? item["confidence"] as? Double
                ?? 0
            let dismissed = item["dismissedByUser"] as? Bool ?? false
            return PhotoMatch.Appearance(
                participantUserId: userId,
                confidence: confidence,
                dismissedByUser: dismissed
            )
        }

        let match = PhotoMatch(
            eventId: eventId,
            ownerUserId: sourceUserId,
            assetLocalId: assetLocalId,
            appearances: appearances,
            capturedAt: capturedAt,
            matchedAt: matchedAt,
            thumbnailPath: data["thumbnailPath"] as? String
        )

        // Preserve the canonical persisted ID contract. PhotoMatch currently
        // derives the same value from event + local asset ID.
        if match.id != matchId {
            throw AppError.decoding("photo \(id) id mismatch")
        }
        return match
    }
}
