import Foundation
import FirebaseFirestore

/// Firestore-backed user document store.
/// Path: users/{uid}
public final class FirebaseUserDirectory: UserDirectory, @unchecked Sendable {
    private let db: Firestore

    public init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    public func fetch(userId: String) async throws -> User {
        do {
            let snapshot = try await db.collection("users").document(userId).getDocument()
            guard snapshot.exists, let data = snapshot.data() else {
                throw AppError.backend(code: "user_not_found", message: "User document does not exist")
            }
            return try Self.decodeUser(id: snapshot.documentID, data: data)
        } catch let error as AppError {
            throw error
        } catch {
            throw Self.mapFirestoreError(error)
        }
    }

    public func save(_ user: User) async throws {
        let data: [String: Any] = [
            "id": user.id,
            "phoneNumber": user.phoneNumber,
            "displayName": user.displayName as Any,
            "hasFaceProfile": user.hasFaceProfile,
            "createdAt": Timestamp(date: user.createdAt)
        ]

        do {
            try await db.collection("users").document(user.id).setData(data, merge: true)
        } catch {
            throw Self.mapFirestoreError(error)
        }
    }

    public func delete(userId: String) async throws {
        do {
            try await db.collection("users").document(userId).delete()
        } catch {
            throw Self.mapFirestoreError(error)
        }
    }

    private static func decodeUser(id: String, data: [String: Any]) throws -> User {
        guard let phoneNumber = data["phoneNumber"] as? String else {
            throw AppError.decoding("users/\(id) missing phoneNumber")
        }

        let displayName = data["displayName"] as? String
        let hasFaceProfile = data["hasFaceProfile"] as? Bool ?? false

        let createdAt: Date
        if let timestamp = data["createdAt"] as? Timestamp {
            createdAt = timestamp.dateValue()
        } else if let date = data["createdAt"] as? Date {
            createdAt = date
        } else {
            throw AppError.decoding("users/\(id) missing createdAt")
        }

        return User(
            id: id,
            phoneNumber: phoneNumber,
            displayName: displayName,
            hasFaceProfile: hasFaceProfile,
            createdAt: createdAt
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
