import Foundation
import FirebaseAuth
import FirebaseFunctions
import FirebaseStorage

/// Live match metadata + thumbnail repository.
/// Originals remain device-local; signed original transfers are a later slice.
public final class FirebaseMatchRepository: MatchRepository, @unchecked Sendable {
    private let storage: Storage
    private let functions: Functions

    public init(
        storage: Storage = .storage(),
        functions: Functions = .functions()
    ) {
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
                "confidence": $0.confidence,
                "faceProfileRevision": $0.faceProfileRevision
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
            _ = try await call("publishMatch", data: payload)
        } catch {
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

        _ = try await call("dismissAppearance", data: [
            "eventId": eventId,
            "matchId": matchId,
            "participantUserId": participantUserId
        ])
    }

    public func myPhotos(eventId: String, userId: String) async throws -> [PhotoMatch] {
        guard Auth.auth().currentUser?.uid == userId else { throw AppError.notAuthenticated }
        return try await matchedPhotos(eventId: eventId)
    }

    public func sharedAlbum(eventId: String) async throws -> [PhotoMatch] {
        guard Auth.auth().currentUser?.uid != nil else { throw AppError.notAuthenticated }
        return try await matchedPhotos(eventId: eventId)
    }

    public func signedOriginalURL(match: PhotoMatch, ttlHours: Int) async throws -> URL {
        throw AppError.originalUnavailable
    }

    private func matchedPhotos(eventId: String) async throws -> [PhotoMatch] {
        let raw = try await call("listMyMatchedPhotos", data: ["eventId": eventId])
        guard let wrapper = raw as? [String: Any],
              let rows = wrapper["photos"] as? [[String: Any]] else {
            throw AppError.decoding("matched photo response is malformed")
        }

        return try rows.map(Self.decodeCallable).sorted { $0.capturedAt > $1.capturedAt }
    }

    private func call(_ name: String, data: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            functions.httpsCallable(name).call(data) { result, error in
                if let error { continuation.resume(throwing: error); return }
                guard let result else {
                    continuation.resume(throwing: AppError.backend(code: "empty_function_result", message: "\(name) returned no result"))
                    return
                }
                continuation.resume(returning: result.data)
            }
        }
    }

    private static func documentId(for value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeCallable(_ data: [String: Any]) throws -> PhotoMatch {
        guard let matchId = data["id"] as? String,
              let eventId = data["eventId"] as? String,
              let sourceUserId = data["sourceUserId"] as? String,
              let assetLocalId = data["assetLocalId"] as? String,
              let capturedAtMillis = numeric(data["capturedAtMillis"]),
              let matchedAtMillis = numeric(data["matchedAtMillis"]) else {
            throw AppError.decoding("matched photo is missing required fields")
        }

        let appearances = (data["appearances"] as? [[String: Any]] ?? []).compactMap { item -> PhotoMatch.Appearance? in
            guard let userId = item["participantUserId"] as? String else { return nil }
            let confidence = numeric(item["confidence"]) ?? 0
            let dismissed = item["dismissedByUser"] as? Bool ?? false
            return PhotoMatch.Appearance(
                participantUserId: userId,
                confidence: confidence,
                faceProfileRevision: item["faceProfileRevision"] as? String ?? "",
                dismissedByUser: dismissed
            )
        }

        let match = PhotoMatch(
            eventId: eventId,
            ownerUserId: sourceUserId,
            assetLocalId: assetLocalId,
            appearances: appearances,
            capturedAt: Date(timeIntervalSince1970: capturedAtMillis / 1000),
            matchedAt: Date(timeIntervalSince1970: matchedAtMillis / 1000),
            thumbnailPath: data["thumbnailPath"] as? String
        )
        guard match.id == matchId else { throw AppError.decoding("matched photo id mismatch") }
        return match
    }

    private static func numeric(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let i = value as? Int64 { return Double(i) }
        return nil
    }
}
