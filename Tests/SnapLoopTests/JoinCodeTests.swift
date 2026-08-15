import XCTest
@testable import SnapLoop

final class JoinCodeTests: XCTestCase {

    func testParsesCleanCode() {
        XCTAssertEqual(JoinCode(input: "ABC234")?.value, "ABC234")
    }

    func testNormalizesCaseSpacesAndDashes() {
        XCTAssertEqual(JoinCode(input: "abc-234")?.value, "ABC234")
        XCTAssertEqual(JoinCode(input: " a b c 2 3 4 ")?.value, "ABC234")
    }

    func testRejectsWrongLength() {
        XCTAssertNil(JoinCode(input: "ABC23"))
        XCTAssertNil(JoinCode(input: "ABC2345"))
    }

    func testRejectsAmbiguousOrInvalidCharacters() {
        XCTAssertNil(JoinCode(input: "ABC2O4"))   // O not allowed
        XCTAssertNil(JoinCode(input: "ABC2!4"))
    }

    func testFormattedGroupsForReadability() {
        XCTAssertEqual(JoinCode(canonical: "ABC234").formatted, "ABC-234")
    }
}
