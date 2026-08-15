import XCTest
@testable import SnapLoop

final class DeepLinkRouterTests: XCTestCase {

    private let token = InviteToken(String(repeating: "A", count: InviteToken.length))!

    func testUniversalLinkTokenPath() {
        let url = URL(string: "https://snaploop.app/e/\(token.value)")!
        XCTAssertEqual(DeepLinkRouter.route(for: url), .joinEventByToken(token))
    }

    func testCustomSchemeHostPath() {
        let url = URL(string: "snaploop://e/\(token.value)")!
        XCTAssertEqual(DeepLinkRouter.route(for: url), .joinEventByToken(token))
    }

    func testCustomSchemeQueryToken() {
        let url = URL(string: "snaploop://join?token=\(token.value)")!
        XCTAssertEqual(DeepLinkRouter.route(for: url), .joinEventByToken(token))
    }

    func testShortCodeLink() {
        let url = URL(string: "https://snaploop.app/c/ABC-234")!
        XCTAssertEqual(DeepLinkRouter.route(for: url), .joinEventByCode(JoinCode(canonical: "ABC234")))
    }

    func testUnknownURLsReturnNil() {
        XCTAssertNil(DeepLinkRouter.route(for: URL(string: "https://snaploop.app/")!))
        XCTAssertNil(DeepLinkRouter.route(for: URL(string: "https://snaploop.app/e/tooshort")!))
        XCTAssertNil(DeepLinkRouter.route(for: URL(string: "https://snaploop.app/unknown/path")!))
    }

    func testManualEntryAcceptsBareCode() {
        XCTAssertEqual(DeepLinkRouter.route(forManualEntry: "abc 234"),
                       .joinEventByCode(JoinCode(canonical: "ABC234")))
    }

    func testManualEntryAcceptsFullURL() {
        XCTAssertEqual(DeepLinkRouter.route(forManualEntry: " https://snaploop.app/e/\(token.value) "),
                       .joinEventByToken(token))
    }

    func testManualEntryRejectsGarbage() {
        XCTAssertNil(DeepLinkRouter.route(forManualEntry: "hello world"))
    }
}
