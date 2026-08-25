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

        let expiredAt =
            (data["expiredAt"] as? Timestamp)?.dateValue()

        let expiresAt =
            (data["expiresAt"] as? Timestamp)?.dateValue()

        let lastBiometricActivityAt =
            (data["lastBiometricActivityAt"] as? Timestamp)?.dateValue()

        let version =
            (data["policyVersion"] as? NSNumber)?.intValue
            ?? data["policyVersion"] as? Int
            ?? 0

        return BiometricConsentRecord(
            userId: userId,
            policyVersion: version,
            disclosureId: data["disclosureId"] as? String ?? "",
            disclosureSHA256: data["disclosureSHA256"] as? String ?? "",
            acceptedAt: acceptedAt,
            withdrawnAt: withdrawnAt,
            expiredAt: expiredAt,
            expiresAt: expiresAt,
            jurisdictionCountry: data["jurisdictionCountry"] as? String ?? "",
            jurisdictionSubdivision: data["jurisdictionSubdivision"] as? String ?? "",
            appVersion: data["appVersion"] as? String ?? "unknown",
            platform: data["platform"] as? String ?? "iOS",
            locale: data["locale"] as? String ?? "unknown",
            acceptedVia: data["acceptedVia"] as? String ?? "unknown",
            age18Attested: data["age18Attested"] as? Bool ?? false,
            noticeAcknowledged: data["noticeAcknowledged"] as? Bool ?? false,
            ownFaceAttested: data["ownFaceAttested"] as? Bool ?? false,
            lastBiometricActivityAt: lastBiometricActivityAt
        )
    }

    public func save(
        _ record: BiometricConsentRecord
    ) async throws {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            functions.httpsCallable("acceptBiometricConsent").call([
                "userId": record.userId,
                "policyVersion": record.policyVersion,
                "disclosureId": record.disclosureId,
                "disclosureSHA256": record.disclosureSHA256,
                "jurisdictionCountry": record.jurisdictionCountry,
                "jurisdictionSubdivision": record.jurisdictionSubdivision,
                "appVersion": record.appVersion,
                "platform": record.platform,
                "locale": record.locale,
                "acceptedVia": record.acceptedVia,
                "age18Attested": record.age18Attested,
                "noticeAcknowledged": record.noticeAcknowledged,
                "ownFaceAttested": record.ownFaceAttested
            ]) { result, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: result?.data as Any)
            }
        }
    }

    public func withdraw(
        userId: String,
        at date: Date
    ) async throws {
        _ = date
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