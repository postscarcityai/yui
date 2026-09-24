import XCTest

/// Scenes for the marketing videos (SOC-3). Like `YuiDemoTests`, each test plays
/// a scripted scene on the demo account while `scripts/promo_videos.py` records
/// the simulator, and writes the moments the edit cuts on (epoch seconds) to
/// `YUI_CLIPS/<name>.json`. Nothing touches the network or a real account: the
/// pairing code is the demo account's placeholder, the agent's replies are
/// scripted lines. Skipped unless `YUI_CLIPS` is set.
final class YuiPromoTests: XCTestCase {
    private var app: XCUIApplication!
    private var clip = ""
    private var marks: [String: Double] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipIf(ProcessInfo.processInfo.environment["YUI_CLIPS"] == nil, "set YUI_CLIPS to record promo scenes")
    }

    private func launch(_ name: String, _ args: [String]) {
        clip = name
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-appearance", "light"] + args
        app.launch()
    }

    /// A question from the person, then `lines` streamed back, 2 s after launch.
    private func ask(_ name: String, _ prompt: String, _ lines: [String], agent: String = "wizard") {
        launch(name, ["-yuiDemoAgents", "-yuiAgent", agent, "-yuiDemoPrompt", prompt, "-yuiDemoDelay", "2",
                      "-yuiThemeDemo", lines.joined(separator: "\\n")])
        _ = app.textFields["Say something nice"].waitForExistence(timeout: 20)
        mark("start")
    }

    private func mark(_ key: String) { marks[key] = Date.now.timeIntervalSince1970 }

    /// Holds the last frame, then writes the marks.
    private func cut(hold: UInt32 = 2) {
        sleep(hold)
        mark("end")
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YUI_CLIPS"]!)
        try? JSONSerialization.data(withJSONObject: marks).write(to: dir.appending(path: "\(clip).json"))
    }

    private func tap(_ e: XCUIElement, wait: TimeInterval = 10, pause: UInt32 = 1) {
        guard e.waitForExistence(timeout: wait) else { return }
        if e.isHittable { e.tap() }
        sleep(pause)
    }

    func testPromoTimer() {
        ask("promo-timer", "Tabata tonight?", ["timer 20/10x8 Tabata +auto"])
        sleep(9)
        cut(hold: 1)
    }

    func testPromoChoose() {
        ask("promo-choose", "Plan my workout", [#"choose "Which split today?" Push|Pull|Legs +other"#])
        sleep(4)
        mark("tap")
        tap(app.buttons["Legs"].firstMatch, pause: 2)
        cut(hold: 1)
    }

    func testPromoChart() {
        ask("promo-chart", "How is my weight this week?", [
            "say Down 2.3 pounds this week, right on plan.",
            #"stat 178.9lb Weight delta=-2.3 spark=181.2|180.6|179.8|178.9 good=down sub="this week""#,
            #"chart line "Weight" x=Mon|Tue|Wed|Thu y=180|179|178.5|178.9 y2=180|179.5|179|178.5 names=Actual|Plan unit=lb"#,
        ], agent: "coach")
        sleep(7)
        cut(hold: 1)
    }

    /// A brand-new account: add an agent, get the code, the host pairs, say hi, first screen.
    func testPromoPair() {
        launch("promo-pair", ["-yuiNoAgents", "-yuiDemoPairAfter", "10", "-yuiDemoReply", [
            "say Hi! Nova here, running on your Mac. My first screen for you:",
            #"choose "What should we try first?" "Plan my day"|"Start a timer"|"Show me a chart""#,
        ].joined(separator: "\\n")])
        let addFirst = app.buttons["Add your first agent"]
        _ = addFirst.waitForExistence(timeout: 20)
        sleep(1)
        mark("start")
        sleep(2)
        addFirst.tap()
        let name = app.textFields.matching(NSPredicate(format: "placeholderValue == %@ OR label == %@",
                                                       "Name, like Nova", "Name, like Nova")).firstMatch
        if name.waitForExistence(timeout: 10) {
            sleep(1)
            name.tap()
            name.typeText("Nova")
            sleep(1)
            name.typeText("\n")  // the keyboard covers the button
            sleep(1)
        }
        let get = app.buttons["Get a pairing code"]
        if get.waitForExistence(timeout: 2), get.isHittable { get.tap() }
        _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Pairing code")).firstMatch
            .waitForExistence(timeout: 10)
        mark("code")
        let connected = app.staticTexts["Nova is connected!"]
        _ = connected.waitForExistence(timeout: 30)
        mark("connected")
        sleep(3)
        tap(app.buttons["Say hi to Nova"], pause: 2)
        mark("chat")
        tap(app.buttons["Hi!"], pause: 0)
        mark("hi")
        sleep(8)
        cut(hold: 1)
    }
}
