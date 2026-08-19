import Foundation
import FirebaseFirestore
import FirebaseFunctions

/// Firestore path:
/// users/{uid}/privacy/biometricConsent
public final class FirebaseBiometricConsentStore:
    BiometricConsentStore,
    @unchecked Sendable {

    private let db: Firestore
    private let functions: Functions

    public init(
        db: Firestore = Firestore.firestore(),
        functions: Functions = Functions.functions()
    ) {
        self.db = db
        self.functions = functions
    }

    public func load(
        userId: String
    ) async throws -> BiometricConsentRecord? {
        let snapshot = try await ref(userId).getDocument()
        guard let data = snapshot.data() else {
            return nil
        }

        let acceptedAt =
            (data["acceptedAt"] as? Timestamp)?.dateValue()
            ?? Date.distantPast

        let withdrawnAt =
            (data["withdrawnAt"] as? Timestamp)?.dateValue()

        let version =
            (data["policyVersion"] as? NSNumber)?.intValue
            ?? data["policyVersion"] as? Int
            ?? 0

        return BiometricConsentRecord(
            userId: userId,
            policyVersion: version,
            acceptedAt: acceptedAt,
            withdrawnAt: withdrawnAt
        )
    }

    public func save(
        _ record: BiometricConsentRecord
    ) async throws {
        var data: [String: Any] = [
            "userId": record.userId,
            "policyVersion": record.policyVersion,
            "acceptedAt": Timestamp(date: record.acceptedAt)
        ]

        if let withdrawnAt = record.withdrawnAt {
            data["withdrawnAt"] = Timestamp(date: withdrawnAt)
        } else {
            data["withdrawnAt"] = NSNull()
        }

        try await ref(record.userId)
            .setData(data, merge: false)
    }

    public func withdraw(
        userId: String,
        at date: Date
    ) async throws {
        _ = date // Server timestamp is authoritative for withdrawal/audit ordering.
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            functions.httpsCallable("withdrawBiometricConsent").call(["userId": userId]) { result, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: result?.data as Any)
            }
        }
    }

    private func ref(
        _ userId: String
    ) -> DocumentReference {
        db.collection("users")
            .document(userId)
            .collection("privacy")
            .document("biometricConsent")
    }
}
