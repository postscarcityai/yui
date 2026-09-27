import XCTest
@testable import Yui

/// A new install forgets the session an earlier install left in the keychain; an update
/// keeps it (feedback AFFVLA66). Only saved defaults count, not launch arguments.
@MainActor
final class FreshInstallTests: XCTestCase {
    private let suite = "yui.tests.fresh-install"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testANewInstallIsFreshOnce() {
        XCTAssertTrue(Account.freshInstall(defaults, domain: suite))
        XCTAssertFalse(Account.freshInstall(defaults, domain: suite), "the second launch still reads as new")
    }

    func testAnUpdateFromAnEarlierBuildIsNotFresh() {
        for key in Account.earlierInstallKeys {
            defaults.removePersistentDomain(forName: suite)
            defaults.set("x", forKey: key)
            XCTAssertFalse(Account.freshInstall(defaults, domain: suite), "an update with \(key) signed out")
            XCTAssertFalse(Account.freshInstall(defaults, domain: suite))
        }
    }
}
