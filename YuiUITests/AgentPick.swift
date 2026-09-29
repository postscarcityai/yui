import XCTest

extension XCUIApplication {
    /// Switches agent the one way there is (YUI-193, YUI-194): the agent bar at the bottom of the drawer (it opens
    /// the switcher), reached from the menu top left, on the stage and in the record. The record's title is plain. A row can carry
    /// a tagline under the name, so it is found by the start of its label. False when the picker
    /// or the row is missing.
    @discardableResult
    func pickAgent(_ name: String, timeout: TimeInterval = 5) -> Bool {
        let menu = buttons["stage-menu"].exists ? buttons["stage-menu"] : buttons["Agent menu"]
        guard menu.waitForExistence(timeout: timeout) else { return false }
        let end = Date().addingTimeInterval(timeout)
        while buttons["drawer-close"].exists, Date() < end { usleep(200_000) }
        menu.tap()
        let pill = buttons["drawer-agent-bar"]
        guard pill.waitForExistence(timeout: timeout) else { return false }
        pill.tap()
        let row = buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
        guard row.waitForExistence(timeout: timeout) else { return false }
        row.tap()
        return true
    }

    /// The plain title in the record's top bar ("Talking to Basil, online"), found by the start of its label.
    func recordTitle(_ name: String = "") -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "identifier == 'record-title' AND label BEGINSWITH %@", "Talking to " + name)).firstMatch
    }

    /// Who you are talking to ("Talking to Basil, online"): read from the record's title, or from the
    /// drawer's agent bar on the stage, which is opened and closed again.
    func talkingTo(timeout: TimeInterval = 5) -> String {
        let title = recordTitle()
        if !descendants(matching: .any)["stage-first"].exists, title.exists { return title.label }
        let menu = buttons["stage-menu"]
        guard menu.waitForExistence(timeout: timeout) else { return "" }
        menu.tap()
        let pill = buttons["drawer-agent-bar"]
        guard pill.waitForExistence(timeout: timeout) else { return "" }
        let label = pill.label
        buttons["drawer-close"].tap()
        return label
    }
}
