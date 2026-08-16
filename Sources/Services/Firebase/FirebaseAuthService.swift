import FirebaseAuth
import Foundation

/// Live `AuthService` backed by Firebase Auth's phone/OTP flow.
///
/// Real users:
/// - normal Firebase phone verification
/// - APNs / reCAPTCHA verification as required
///
/// Simulator DEBUG builds:
/// - app verification is disabled so Firebase fictional test numbers can be
///   tested without APNs or reCAPTCHA.
///
/// IMPORTANT:
/// `isAppVerificationDisabledForTesting` must NEVER be enabled in production.
public final class FirebaseAuthService: AuthService, @unchecked Sendable {

    public init() {}

    public var currentUserId: String? {
        Auth.auth().currentUser?.uid
    }

    public func startPhoneVerification(phoneNumber: String) async throws -> String {

        // Firebase explicitly supports disabling app verification for
        // integration/development testing with fictional phone numbers.
        //
        // Restrict this to DEBUG + Simulator so it cannot accidentally affect
        // a production build or a physical-device release.
        #if DEBUG && targetEnvironment(simulator)
        Auth.auth().settings?.isAppVerificationDisabledForTesting = true
        #endif

        return try await withCheckedThrowingContinuation { continuation in

            PhoneAuthProvider.provider().verifyPhoneNumber(
                phoneNumber,
                uiDelegate: nil
            ) { verificationId, error in

                if let error {
                    let nsError = error as NSError

                    print("❌ FIREBASE PHONE AUTH FAILED")
                    print("Domain: \(nsError.domain)")
                    print("Code: \(nsError.code)")
                    print("Description: \(nsError.localizedDescription)")
                    print("UserInfo: \(nsError.userInfo)")

                    continuation.resume(
                        throwing: Self.mapError(error)
                    )
                    return
                }

                guard let verificationId else {
                    continuation.resume(
                        throwing: AppError.unknown(
                            "Firebase returned no verification id"
                        )
                    )
                    return
                }

                continuation.resume(returning: verificationId)
            }
        }
    }

    public func confirmVerification(
        verificationId: String,
        code: String
    ) async throws -> String {

        let credential = PhoneAuthProvider.provider().credential(
            withVerificationID: verificationId,
            verificationCode: code
        )

        return try await withCheckedThrowingContinuation { continuation in

            Auth.auth().signIn(with: credential) { result, error in

                if let error {
                    continuation.resume(
                        throwing: Self.mapError(error)
                    )
                    return
                }

                guard let uid = result?.user.uid else {
                    continuation.resume(
                        throwing: AppError.unknown(
                            "Sign-in succeeded without a user"
                        )
                    )
                    return
                }

                continuation.resume(returning: uid)
            }
        }
    }

    public func signOut() throws {
        do {
            try Auth.auth().signOut()
        } catch {
            throw AppError.unknown("\(error)")
        }
    }

    /// Maps Firebase Auth errors into SnapLoop's own AppError types.
    static func mapError(_ error: Error) -> AppError {

        let nsError = error as NSError

        guard nsError.domain == AuthErrorDomain else {
            return .network(
                underlying: nsError.localizedDescription
            )
        }

        guard let code = AuthErrorCode.Code(
            rawValue: nsError.code
        ) else {
            return .backend(
                code: "\(nsError.code)",
                message: nsError.localizedDescription
            )
        }

        switch code {

        case .invalidPhoneNumber,
             .missingPhoneNumber:

            return .invalidPhoneNumber

        case .invalidVerificationCode,
             .missingVerificationCode:

            return .invalidVerificationCode

        case .sessionExpired,
             .invalidVerificationID,
             .missingVerificationID:

            return .verificationExpired

        case .networkError:

            return .network(
                underlying: nsError.localizedDescription
            )

        case .tooManyRequests:

            return .backend(
                code: "too_many_requests",
                message:
                    "Too many attempts. Please wait a bit and try again."
            )

        default:

            return .backend(
                code: "\(code.rawValue)",
                message: nsError.localizedDescription
            )
        }
    }
}
