import Foundation
import FirebaseFirestore

/// Firestore-backed private face-profile store.
/// Path: users/{uid}/faceProfile/current
///
/// The profile contains only the on-device-generated embedding and metadata.
/// The source selfie itself is not written to Firestore by this store.
public final class FirebaseFaceProfileStore: FaceProfileStore, @unchecked Sendable {
    private let db: Firestore

    public init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    public func load(userId: String) async throws -> FaceProfile? {
        do {
            let snapshot = try await ref(userId: userId).getDocument()
            guard snapshot.exists, let data = snapshot.data() else { return nil }
            return try Self.decodeProfile(userId: userId, data: data)
        } catch let error as AppError {
            throw error
        } catch {
            throw Self.mapFirestoreError(error)
        }
    }

    public func save(_ profile: FaceProfile) async throws {
        let data: [String: Any] = [
            "userId": profile.userId,
            "embedding": profile.embedding.vector.map(Double.init),
            "version": profile.version,
            "updatedAt": Timestamp(date: profile.updatedAt)
        ]

        do {
            try await ref(userId: profile.userId).setData(data, merge: false)
        } catch {
            throw Self.mapFirestoreError(error)
        }
    }

    public func delete(userId: String) async throws {
        do {
            try await ref(userId: userId).delete()
        } catch {
            throw Self.mapFirestoreError(error)
        }
    }

    private func ref(userId: String) -> DocumentReference {
        db.collection("users")
            .document(userId)
            .collection("faceProfile")
            .document("current")
    }

    private static func decodeProfile(userId: String, data: [String: Any]) throws -> FaceProfile {
        let vector: [Float]
        if let doubles = data["embedding"] as? [Double] {
            vector = doubles.map(Float.init)
        } else if let numbers = data["embedding"] as? [NSNumber] {
            vector = numbers.map { $0.floatValue }
        } else {
            throw AppError.decoding("faceProfile/current missing embedding")
        }

        guard !vector.isEmpty else {
            throw AppError.decoding("faceProfile/current has empty embedding")
        }

        let version = data["version"] as? Int ?? (data["version"] as? NSNumber)?.intValue ?? 1

        let updatedAt: Date
        if let timestamp = data["updatedAt"] as? Timestamp {
            updatedAt = timestamp.dateValue()
        } else if let date = data["updatedAt"] as? Date {
            updatedAt = date
        } else {
            throw AppError.decoding("faceProfile/current missing updatedAt")
        }

        return FaceProfile(
            userId: userId,
            embedding: FaceEmbedding(normalized: vector),
            version: version,
            updatedAt: updatedAt
        )
    }

    private static func mapFirestoreError(_ error: Error) -> AppError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .network(underlying: nsError.localizedDescription)
        }
        return .backend(code: "firestore_\(nsError.code)", message: nsError.localizedDescription)
    }
}
