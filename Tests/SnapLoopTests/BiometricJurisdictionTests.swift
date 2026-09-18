import XCTest
@testable import SnapLoop

final class BiometricJurisdictionTests: XCTestCase {
    func testIndiaIsAvailableWithoutSubdivision() {
        XCTAssertTrue(BiometricJurisdiction(countryCode: "IN").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "IN", subdivisionCode: "ON").isFaceMatchAvailable)
    }

    func testOntarioIsAvailableAndDefaultForCanada() {
        XCTAssertEqual(BiometricJurisdictionCatalog.firstAvailableSubdivision(for: "CA"), "ON")
        XCTAssertTrue(BiometricJurisdiction(countryCode: "CA", subdivisionCode: "ON").isFaceMatchAvailable)
    }

    func testQuebecIsNotOfferedOrAvailable() {
        XCTAssertFalse(BiometricJurisdictionCatalog.canadianSubdivisionCodes.contains("QC"))
        XCTAssertFalse(BiometricJurisdiction(countryCode: "CA", subdivisionCode: "QC").isFaceMatchAvailable)
    }

    func testOtherCanadianSubdivisionsRemainAvailable() {
        let expected = Set(["AB", "BC", "MB", "NB", "NL", "NS", "NT", "NU", "ON", "PE", "SK", "YT"])
        XCTAssertEqual(BiometricJurisdictionCatalog.canadianSubdivisionCodes, expected)
        for code in expected {
            XCTAssertTrue(BiometricJurisdiction(countryCode: "CA", subdivisionCode: code).isFaceMatchAvailable)
        }
    }

    func testUnsupportedCountryCannotEnableFaceMatch() {
        XCTAssertFalse(BiometricJurisdiction(countryCode: "US").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "GB").isFaceMatchAvailable)
    }
}
