import FirebaseAuth
import XCTest
@testable import SnapLoop

/// Tests only the pure error-mapping function — no network, no Firebase
/// project needed. Uses `AuthErrorCode`'s own cases to build the test `NSError`
/// rather than hardcoding numeric codes, so this stays correct even if the
/// SDK's internal raw values ever change.
final class FirebaseAuthServiceMappingTests: XCTestCase {

    private func nsError(_ code: AuthErrorCode) -> NSError {
        NSError(domain: AuthErrorDomain, code: code.rawValue)
    }

    func testInvalidPhoneNumberMapsToInvalidPhoneNumber() {
        XCTAssertEqual(FirebaseAuthService.mapError(nsError(.invalidPhoneNumber)), .invalidPhoneNumber)
    }

    func testMissingPhoneNumberAlsoMapsToInvalidPhoneNumber() {
        XCTAssertEqual(FirebaseAuthService.mapError(nsError(.missingPhoneNumber)), .invalidPhoneNumber)
    }

    func testInvalidVerificationCodeMapsCorrectly() {
        XCTAssertEqual(FirebaseAuthService.mapError(nsError(.invalidVerificationCode)), .invalidVerificationCode)
    }

    func testMissingVerificationCodeAlsoMapsToInvalidVerificationCode() {
        XCTAssertEqual(FirebaseAuthService.mapError(nsError(.missingVerificationCode)), .invalidVerificationCode)
    }

    func testSessionExpiredMapsToVerificationExpired() {
        XCTAssertEqual(FirebaseAuthService.mapError(nsError(.sessionExpired)), .verificationExpired)
    }

    func testInvalidVerificationIDAlsoMapsToVerificationExpired() {
        XCTAssertEqual(FirebaseAuthService.mapError(nsError(.invalidVerificationID)), .verificationExpired)
    }

    func testNetworkErrorMapsToNetworkCase() {
        guard case .network = FirebaseAuthService.mapError(nsError(.networkError)) else {
            return XCTFail("expected .network")
        }
    }

    func testTooManyRequestsMapsToBackendWithHumanMessage() {
        let mapped = FirebaseAuthService.mapError(nsError(.tooManyRequests))
        guard case .backend(let code, let message) = mapped else {
            return XCTFail("expected .backend")
        }
        XCTAssertEqual(code, "too_many_requests")
        XCTAssertFalse(message.isEmpty)
    }

    func testUnrecognizedAuthDomainCodeFallsBackToBackend() {
        // A code with no case in AuthErrorCode's known set still round-trips
        // through the `default:` branch rather than crashing.
        let error = NSError(domain: AuthErrorDomain, code: -1)
        guard case .backend = FirebaseAuthService.mapError(error) else {
            return XCTFail("expected .backend fallback for an unrecognized Auth error code")
        }
    }

    func testForeignErrorDomainMapsToNetwork() {
        let foreign = NSError(domain: "com.example.other", code: 999)
        guard case .network = FirebaseAuthService.mapError(foreign) else {
            return XCTFail("expected .network fallback for a non-Auth error domain")
        }
    }
}
