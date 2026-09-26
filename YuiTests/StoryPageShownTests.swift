import XCTest
@testable import Yui

/// The page showing always has its words on (TestFlight feedback AKsr0Ha8, build 96:
/// "Sometimes I come to these pages and they don't come back"). A full-screen deck
/// showed its bars and arrows around an empty page: the words waited for an
/// onAppear/onChange that the paging view never sent. Now whether a page's words
/// show depends on `active` alone; the events only pick the direction they come from.
@MainActor
final class StoryPageShownTests: XCTestCase {
    func testTheShowingPageIsOnWhateverEventsItMissed() {
        for phase in [StoryPage.Phase.before, .on, .after] {
            XCTAssertEqual(StoryPage.shown(active: true, phase: phase), .on, "active page stuck at \(phase)")
        }
        XCTAssertEqual(StoryPage.shown(active: false, phase: .before), .before)
        XCTAssertEqual(StoryPage.shown(active: false, phase: .after), .after)
    }
}
