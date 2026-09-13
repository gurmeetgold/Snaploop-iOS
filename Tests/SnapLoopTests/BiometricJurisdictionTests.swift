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

    func testQuebecIsDisplayedButFaceMatchRemainsUnavailable() {
        XCTAssertTrue(BiometricJurisdictionCatalog.canadianSubdivisionCodes.contains("QC"))
        XCTAssertFalse(BiometricJurisdictionCatalog.faceMatchCanadianSubdivisionCodes.contains("QC"))
        XCTAssertFalse(BiometricJurisdiction(countryCode: "CA", subdivisionCode: "QC").isFaceMatchAvailable)
    }

    func testOtherCanadianSubdivisionsRemainAvailable() {
        let expected = Set(["AB", "BC", "MB", "NB", "NL", "NS", "NT", "NU", "ON", "PE", "SK", "YT"])
        XCTAssertEqual(BiometricJurisdictionCatalog.faceMatchCanadianSubdivisionCodes, expected)
        for code in expected {
            XCTAssertTrue(BiometricJurisdiction(countryCode: "CA", subdivisionCode: code).isFaceMatchAvailable)
        }
    }

    func testCountryCatalogIsGlobalRatherThanRolloutOnly() {
        let codes = Set(BiometricJurisdictionCatalog.countries.map(\.code))
        XCTAssertTrue(codes.contains("CA"))
        XCTAssertTrue(codes.contains("IN"))
        XCTAssertTrue(codes.contains("US"))
        XCTAssertGreaterThan(codes.count, 100)
    }

    func testUnsupportedCountryCannotEnableFaceMatch() {
        XCTAssertFalse(BiometricJurisdiction(countryCode: "US").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "GB").isFaceMatchAvailable)
    }
}
