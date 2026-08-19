import Foundation
import FirebaseFirestore
import FirebaseFunctions

/// Firestore-backed user document store.
/// Path: users/{uid}
///
/// Identity fields are server-owned. The client may request profile sync, but
/// the backend derives the canonical phone number from Firebase Auth rather
/// than trusting a client-provided value.
public final class FirebaseUserDirectory: UserDirectory, @unchecked Sendable {
    private let db: Firestore
    private let functions: Functions

    public init(
        db: Firestore = Firestore.firestore(),
        functions: Functions = Functions.functions()
    ) {
        self.db = db
        self.functions = functions
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
        let payload: [String: Any] = [
            "userId": user.id,
            "displayName": user.displayName ?? NSNull()
        ]

        do {
            _ = try await Self.call(
                functions: functions,
                name: "syncMyUserProfile",
                data: payload
            )
        } catch {
            throw Self.mapFunctionsError(error)
        }
    }

    public func delete(userId: String) async throws {
        do {
            _ = try await Self.call(
                functions: functions,
                name: "deleteMyAccount",
                data: ["userId": userId]
            )
        } catch {
            throw Self.mapFunctionsError(error)
        }
    }

    private static func call(
        functions: Functions,
        name: String,
        data: [String: Any]
    ) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            functions.httpsCallable(name).call(data) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result?.data as Any)
            }
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

    private static func mapFunctionsError(_ error: Error) -> AppError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .network(underlying: nsError.localizedDescription)
        }
        if nsError.domain == FunctionsErrorDomain,
           let code = FunctionsErrorCode(rawValue: nsError.code) {
            switch code {
            case .unauthenticated:
                return .notAuthenticated
            case .failedPrecondition:
                return .backend(code: "failed_precondition", message: nsError.localizedDescription)
            case .permissionDenied:
                return .backend(code: "permission_denied", message: nsError.localizedDescription)
            default:
                return .backend(code: "function_\(code.rawValue)", message: nsError.localizedDescription)
            }
        }
        return .backend(code: "function_\(nsError.code)", message: nsError.localizedDescription)
    }

    private static func mapFirestoreError(_ error: Error) -> AppError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .network(underlying: nsError.localizedDescription)
        }
        return .backend(code: "firestore_\(nsError.code)", message: nsError.localizedDescription)
    }
}
