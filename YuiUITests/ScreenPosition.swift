import XCTest

/// The screens have no dots (YUI-168, Chris: "let the user rely on instinct that they can
/// swipe"). VoiceOver's `page-position` element says where you are (the screen's name, "3 of 5"; `page-shown-N` carries the number)
/// and pages when adjusted; the tests read where they are from it and move with swipes.
extension XCUIApplication {
    var pagePosition: XCUIElement { descendants(matching: .any)["page-position"].firstMatch }

    /// The screen on show: 1 on the chat or the home, else the screen's number. Nil with only one screen.
    var screenShown: Int? {
        guard pagePosition.exists else { return nil }
        let shown = descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'page-shown-'")).firstMatch
        guard shown.exists else { return 1 }
        return Int(shown.identifier.dropFirst("page-shown-".count)) ?? 1
    }

    /// How many screens there are: the N in "2 of N". 1 when there is only the one.
    var screenCount: Int {
        guard pagePosition.exists, let v = pagePosition.value as? String,
              let n = v.split(separator: " ").last.flatMap({ Int($0) }) else { return 1 }
        return n
    }

    /// Pages to screen `n` one swipe at a time, from the edge, where only the swipe lives.
    /// (XCTest cannot adjust an element on iOS; VoiceOver's swipe up and down do the same.)
    func goToScreen(_ n: Int) {
        for _ in 0..<14 {
            guard let at = screenShown, at != n else { return }
            let from = coordinate(withNormalizedOffset: CGVector(dx: at < n ? 0.96 : 0.04, dy: 0.45))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: at < n ? -260 : 260, dy: 0)))
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.screenShown != at }, object: nil)
            _ = XCTWaiter.wait(for: [moved], timeout: 3)
        }
    }
}

extension XCTestCase {
    /// Waits for screen `n` to be the one on show.
    func waitScreen(_ app: XCUIApplication, _ n: Int, _ message: String, timeout: TimeInterval = 8,
                    file: StaticString = #filePath, line: UInt = #line) {
        let p = NSPredicate { _, _ in app.screenShown == n }
        let e = XCTNSPredicateExpectation(predicate: p, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: timeout), .completed,
                       "\(message) (on \(app.screenShown.map(String.init) ?? "the only screen"))", file: file, line: line)
    }

    /// Waits for `count` screens.
    func waitScreens(_ app: XCUIApplication, _ count: Int, _ message: String, timeout: TimeInterval = 20,
                     file: StaticString = #filePath, line: UInt = #line) {
        let p = NSPredicate { _, _ in app.screenCount == count }
        let e = XCTNSPredicateExpectation(predicate: p, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: timeout), .completed,
                       "\(message) (\(app.screenCount) screens)", file: file, line: line)
    }
}
