import XCTest
@testable import SnapLoop

final class BiometricJurisdictionTests: XCTestCase {
    func testIndiaStorefrontResolvesToIndia() {
        XCTAssertEqual(
            ConsentStorefrontResolver.appCountryCode(storefrontCountryCode: "IND", localeRegionCode: "CA"),
            "IN"
        )
    }

    func testCanadaStorefrontResolvesToCanada() {
        XCTAssertEqual(
            ConsentStorefrontResolver.appCountryCode(storefrontCountryCode: "CAN", localeRegionCode: "IN"),
            "CA"
        )
    }

    func testKnownUnsupportedStorefrontDoesNotFallBackToLocale() {
        XCTAssertNil(
            ConsentStorefrontResolver.appCountryCode(storefrontCountryCode: "USA", localeRegionCode: "CA")
        )
    }

    func testLocaleFallbackUsedOnlyWhenStorefrontUnavailable() {
        XCTAssertEqual(
            ConsentStorefrontResolver.appCountryCode(storefrontCountryCode: nil, localeRegionCode: "CA"),
            "CA"
        )
    }

    func testOntarioIsDefaultCanadianSubdivision() {
        XCTAssertEqual(BiometricJurisdictionCatalog.firstAvailableSubdivision(for: "CA"), "ON")
    }

    func testCanadianCatalogExcludesQuebec() {
        XCTAssertFalse(BiometricJurisdictionCatalog.canadianSubdivisionCodes.contains("QC"))
        XCTAssertFalse(BiometricJurisdiction(countryCode: "CA", subdivisionCode: "QC").isFaceMatchAvailable)
    }

    func testSupportedCanadianProvinceIsAvailable() {
        XCTAssertTrue(BiometricJurisdiction(countryCode: "CA", subdivisionCode: "ON").isFaceMatchAvailable)
    }

    func testIndiaRemainsAvailableWithoutSubdivision() {
        XCTAssertTrue(BiometricJurisdiction(countryCode: "IN").isFaceMatchAvailable)
    }
}
