import XCTest
@testable import ramnotes

final class LoginTests: XCTestCase {
    func testOnlyExactLoginURLSetsHiddenBeforeLaunchOriginFinishes() throws {
        var origin = LaunchOrigin()

        origin.receive([LaunchOrigin.loginURL])

        XCTAssertTrue(origin.hidden)
        XCTAssertFalse(origin.finished)

        let invalidValues = [
            "other-scheme://login",
            "ramnotes-login://other",
            "ramnotes-login://login/path",
            "ramnotes-login://login/",
            "ramnotes-login://login?source=test",
            "ramnotes-login://login#fragment",
            "ramnotes-login://user:secret@login",
            "ramnotes-login://login:1234",
            "RAMNOTES-LOGIN://login",
            "ramnotes-login://LOGIN",
            "ramnotes-login://login/%6Cogin"
        ]
        for value in invalidValues {
            let url = try XCTUnwrap(URL(string: value), "Expected a parseable URL for \(value)")
            var candidate = LaunchOrigin()
            candidate.receive([url])
            XCTAssertFalse(candidate.hidden, "This URL must not be treated as the login launch hint: \(value)")
            XCTAssertFalse(candidate.finished)
        }
    }

    func testManualReopenFinishesVisibleAndIgnoresLaterLoginHint() {
        var origin = LaunchOrigin()
        origin.receive([LaunchOrigin.loginURL])
        XCTAssertTrue(origin.hidden)

        origin.manualReopen()
        XCTAssertFalse(origin.hidden)
        XCTAssertTrue(origin.finished)

        origin.receive([LaunchOrigin.loginURL])
        XCTAssertFalse(origin.hidden)
        XCTAssertTrue(origin.finished)
    }

    func testFinishPreventsLaterLoginHintFromHidingLaunch() {
        var origin = LaunchOrigin()
        origin.finish()

        origin.receive([LaunchOrigin.loginURL])

        XCTAssertFalse(origin.hidden)
        XCTAssertTrue(origin.finished)
    }

    func testAppBundleContainsConfiguredLoginHelperAndURLScheme() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.ramnotes.RAMnotes")
        let appBundleURL = Bundle.main.bundleURL
        let helperURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LoginItems", isDirectory: true)
            .appendingPathComponent("ramnotesLoginHelper.app", isDirectory: true)
        let helperBundle = try XCTUnwrap(Bundle(url: helperURL), "The embedded login helper bundle should be present")

        XCTAssertEqual(helperBundle.bundleIdentifier, "com.ramnotes.RAMnotes.LoginHelper")
        let executableURL = try XCTUnwrap(helperBundle.executableURL, "The login helper should declare an executable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: executableURL.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executableURL.path))

        let urlTypes = try XCTUnwrap(Bundle(url: appBundleURL)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("ramnotes-login"), "The main app bundle should register the login URL scheme")
    }
}
