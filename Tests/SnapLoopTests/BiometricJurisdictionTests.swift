import XCTest
@testable import SnapLoop

final class BiometricJurisdictionTests: XCTestCase {
    func testIndiaIsAvailableWithoutSubdivision() {
        XCTAssertTrue(BiometricJurisdiction(countryCode: "IN").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "IN", subdivisionCode: "ON").isFaceMatchAvailable)
    }

    func testCanadaIsBlockedForLaunch() {
        XCTAssertFalse(
            BiometricJurisdiction(countryCode: "CA", subdivisionCode: "ON").isFaceMatchAvailable
        )
    }

    func testQuebecIsNotOfferedOrAvailable() {
        XCTAssertFalse(BiometricJurisdictionCatalog.canadianSubdivisionCodes.contains("QC"))
        XCTAssertFalse(
            BiometricJurisdiction(countryCode: "CA", subdivisionCode: "QC").isFaceMatchAvailable
        )
    }

    func testCanadianSubdivisionMetadataIsRetainedButUnavailable() {
        let expected = Set([
            "AB", "BC", "MB", "NB", "NL", "NS",
            "NT", "NU", "ON", "PE", "SK", "YT"
        ])

        XCTAssertEqual(BiometricJurisdictionCatalog.canadianSubdivisionCodes, expected)
        XCTAssertEqual(BiometricJurisdictionCatalog.firstAvailableSubdivision(for: "CA"), "ON")

        for code in expected {
            XCTAssertFalse(
                BiometricJurisdiction(
                    countryCode: "CA",
                    subdivisionCode: code
                ).isFaceMatchAvailable,
                "Canada subdivision \(code) must remain blocked during India-only launch"
            )
        }
    }

    func testLaunchCountryCatalogContainsIndiaOnly() {
        XCTAssertEqual(BiometricJurisdictionCatalog.countries.map(\.code), ["IN"])
    }

    func testUnsupportedCountryCannotEnableFaceMatch() {
        XCTAssertFalse(BiometricJurisdiction(countryCode: "US").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "GB").isFaceMatchAvailable)
    }
}
