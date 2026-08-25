import FirebaseAuth
import Foundation

private final class AuthStateListenerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    var handle: AuthStateDidChangeListenerHandle?

    func markResumedIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }

    var hasResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didResume
    }
}

/// Live `AuthService` backed by Firebase Auth's phone/OTP flow.
public final class FirebaseAuthService: AuthService, @unchecked Sendable {

    public init() {}

    public var currentUserId: String? {
        Auth.auth().currentUser?.uid
    }

    /// Waits for Firebase's initial persisted-auth restoration instead of
    /// temporarily presenting the phone screen while Keychain state hydrates.
    public func resolvedCurrentUserId() async -> String? {
        if let uid = currentUserId { return uid }

        return await withCheckedContinuation { continuation in
            let box = AuthStateListenerBox()
            let auth = Auth.auth()
            let handle = auth.addStateDidChangeListener { auth, user in
                guard box.markResumedIfNeeded() else { return }
                if let handle = box.handle {
                    auth.removeStateDidChangeListener(handle)
                    box.handle = nil
                }
                continuation.resume(returning: user?.uid)
            }
            box.handle = handle
            if box.hasResumed {
                auth.removeStateDidChangeListener(handle)
                box.handle = nil
            }
        }
    }

    public func startPhoneVerification(phoneNumber: String) async throws -> String {
        #if DEBUG && targetEnvironment(simulator)
        Auth.auth().settings?.isAppVerificationDisabledForTesting = true
        #endif

        return try await withCheckedThrowingContinuation { continuation in
            PhoneAuthProvider.provider().verifyPhoneNumber(phoneNumber, uiDelegate: nil) { verificationId, error in
                if let error {
                    let nsError = error as NSError
                    Log.auth.error("Firebase phone app verification failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
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
            withVerificationID: verificationId,
            verificationCode: code
        )

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
        do { try Auth.auth().signOut() }
        catch { throw AppError.unknown("\(error)") }
    }

    static func mapError(_ error: Error) -> AppError {
        let nsError = error as NSError
        guard nsError.domain == AuthErrorDomain else {
            return .network(underlying: nsError.localizedDescription)
        }
        guard let code = AuthErrorCode(rawValue: nsError.code) else {
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
            return .backend(code: "too_many_requests", message: "Too many attempts. Please wait a bit and try again.")
        case .missingAppToken, .notificationNotForwarded, .appNotVerified,
             .captchaCheckFailed, .webContextCancelled, .appVerificationUserInteractionFailure:
            return .backend(
                code: "phone_app_verification_failed",
                message: "Phone verification couldn't complete. Please try again."
            )
        default:
            return .backend(code: "\(code.rawValue)", message: nsError.localizedDescription)
        }
    }
}
