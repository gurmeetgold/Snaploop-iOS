import FirebaseAuth
import Foundation

/// Live `AuthService` backed by Firebase Auth's phone/OTP flow.
///
/// This is the first seam wired to a real backend (see `AppEnvironment.live()`
/// and its wiring checklist). Everything downstream — the user's Firestore
/// profile (`UserDirectory`), their face profile (`FaceProfileStore`), events,
/// matches — is still the in-memory stub from `.dev()` until each is wired in
/// turn. Signing in here proves identity via Firebase Auth; it does not yet
/// persist anything to Firestore.
///
/// Wraps the SDK's completion-handler APIs with `withCheckedThrowingContinuation`
/// rather than relying on any async overload the installed SDK version may or
/// may not expose, so this compiles against a wide range of Firebase iOS SDK
/// versions.
public final class FirebaseAuthService: AuthService, @unchecked Sendable {

    public init() {}

    public var currentUserId: String? {
        Auth.auth().currentUser?.uid
    }

    public func startPhoneVerification(phoneNumber: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            PhoneAuthProvider.provider().verifyPhoneNumber(phoneNumber, uiDelegate: nil) { verificationId, error in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                guard let verificationId else {
                    continuation.resume(throwing: AppError.unknown("Firebase returned no verification id"))
                    return
                }
                continuation.resume(returning: verificationId)
            }
        }
    }

    public func confirmVerification(verificationId: String, code: String) async throws -> String {
        let credential = PhoneAuthProvider.provider().credential(
            withVerificationID: verificationId, verificationCode: code)
        return try await withCheckedThrowingContinuation { continuation in
            Auth.auth().signIn(with: credential) { result, error in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                guard let uid = result?.user.uid else {
                    continuation.resume(throwing: AppError.unknown("Sign-in succeeded without a user"))
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

    /// Maps a Firebase Auth error to our closed `AppError` set, so the UI never
    /// sees an `NSError` or a Firebase-specific type. Internal (not private) so
    /// it's directly unit-testable without going through the network.
    ///
    /// Two distinct failure modes, kept apart deliberately: an error from
    /// *outside* the Auth domain (e.g. a raw network failure) can't be
    /// attributed to any specific Auth condition, so it maps to `.network`. An
    /// error *from* the Auth domain whose code we don't specifically recognize
    /// still maps to `.backend` — we know it's an auth failure, just not which
    /// one — rather than being misreported as a generic network issue.
    static func mapError(_ error: Error) -> AppError {
        let nsError = error as NSError
        guard nsError.domain == AuthErrorDomain else {
            return .network(underlying: nsError.localizedDescription)
        }
        guard let code = AuthErrorCode.Code(rawValue: nsError.code) else {
            return .backend(code: "\(nsError.code)", message: nsError.localizedDescription)
        }
        switch code {
        case .invalidPhoneNumber, .missingPhoneNumber:
            return .invalidPhoneNumber
        case .invalidVerificationCode, .missingVerificationCode:
            return .invalidVerificationCode
        case .sessionExpired, .invalidVerificationID, .missingVerificationID:
            return .verificationExpired
        case .networkError:
            return .network(underlying: nsError.localizedDescription)
        case .tooManyRequests:
            return .backend(code: "too_many_requests",
                            message: "Too many attempts. Please wait a bit and try again.")
        default:
            return .backend(code: "\(code.rawValue)", message: nsError.localizedDescription)
        }
    }
}
