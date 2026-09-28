import XCTest

extension XCUIApplication {
    /// Switches agent the one way there is (YUI-167): the pill top left, on the stage or in
    /// the record, then the agent's row. A row can carry a tagline under the name, so it is
    /// found by the start of its label. False when the pill or the row is missing.
    @discardableResult
    func pickAgent(_ name: String, timeout: TimeInterval = 5) -> Bool {
        let pill = [buttons["stage-agents"], buttons["record-agents"]].first { $0.exists && $0.isHittable }
            ?? buttons["record-agents"]
        guard pill.waitForExistence(timeout: timeout) else { return false }
        pill.tap()
        let row = buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
        guard row.waitForExistence(timeout: timeout) else { return false }
        row.tap()
        return true
    }
}
