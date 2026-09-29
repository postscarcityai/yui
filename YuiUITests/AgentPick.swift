import XCTest

extension XCUIApplication {
    /// Switches agent the one way there is (YUI-193): the agent bar at the bottom of the drawer (it opens the switcher) on
    /// the stage (the menu top left opens it), the pill in the record's nav bar. A row can carry
    /// a tagline under the name, so it is found by the start of its label. False when the picker
    /// or the row is missing.
    @discardableResult
    func pickAgent(_ name: String, timeout: TimeInterval = 5) -> Bool {
        let record = buttons["record-agents"]
        let pill: XCUIElement
        if !descendants(matching: .any)["stage-first"].exists, record.exists && record.isHittable {
            pill = record
        } else {
            let menu = buttons["stage-menu"]
            guard menu.waitForExistence(timeout: timeout) else { return false }
            let end = Date().addingTimeInterval(timeout)
            while buttons["drawer-close"].exists, Date() < end { usleep(200_000) }
            menu.tap()
            pill = buttons["drawer-agent-bar"]
        }
        guard pill.waitForExistence(timeout: timeout) else { return false }
        pill.tap()
        let row = buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
        guard row.waitForExistence(timeout: timeout) else { return false }
        row.tap()
        return true
    }

    /// Who the agent picker says you are talking to ("Talking to Basil, online"): read from the
    /// record's pill, or from the drawer's on the stage, which is opened and closed again.
    func talkingTo(timeout: TimeInterval = 5) -> String {
        let record = buttons["record-agents"]
        if !descendants(matching: .any)["stage-first"].exists, record.exists && record.isHittable { return record.label }
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
