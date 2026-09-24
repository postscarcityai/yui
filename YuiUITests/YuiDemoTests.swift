import XCTest

/// Demo clips for the site and social (SOC-2). Each test plays one scripted
/// Yui Lines reply on the demo account and taps through it like a person would,
/// while `scripts/demo_clips.py` records the simulator. The test writes when the
/// scene starts and ends to `YUI_CLIPS/<name>.json` so the script can trim the
/// recording to exactly that. Skipped unless `YUI_CLIPS` is set.
final class YuiDemoTests: XCTestCase {
    private var app: XCUIApplication!
    private var clip = ""
    private var start = 0.0

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipIf(ProcessInfo.processInfo.environment["YUI_CLIPS"] == nil, "set YUI_CLIPS to record demo clips")
    }

    /// Launches the demo account with `prompt` from the person and `lines` streamed back.
    private func play(_ name: String, _ prompt: String, _ lines: [String], agent: String = "wizard") {
        self.clip = name
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", agent, "-appearance", "light",
                               "-yuiDemoPrompt", prompt, "-yuiDemoDelay", "4", "-yuiThemeDemo", lines.joined(separator: "\\n")]
        app.launch()
        // The prompt lands 4 s after launch; this wait usually eats about 2 of them.
        _ = app.textFields["Say something nice"].waitForExistence(timeout: 20)
        start = Date.now.timeIntervalSince1970
    }

    /// Holds the last frame, then writes the scene's start and end (epoch seconds).
    private func cut(hold: UInt32 = 2) {
        sleep(hold)
        let marks: [String: Any] = ["name": clip, "start": start, "end": Date.now.timeIntervalSince1970]
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YUI_CLIPS"]!)
        try? JSONSerialization.data(withJSONObject: marks).write(to: dir.appending(path: "\(clip).json"))
    }

    /// Taps `e` once it is on screen. A clip with a missed tap is still a clip, so no failure.
    private func tap(_ e: XCUIElement, wait: TimeInterval = 10, pause: UInt32 = 1) {
        guard e.waitForExistence(timeout: wait) else { return }
        var n = 0
        while !(e.isHittable && e.frame.minY > 100 && e.frame.maxY < app.frame.maxY - 90), n < 6 {
            app.swipeUp(velocity: .slow); n += 1
        }
        if e.isHittable { e.tap() }
        sleep(pause)
    }

    func testTimer() {
        play("timer", "Tabata tonight?", [
            "say Tabata time. Eight rounds, 20 on and 10 off.",
            "timer@hiit 20/10x8 Tabata +auto",
        ])
        sleep(10)
        cut()
    }

    func testChoose() {
        play("choose", "Plan my workout", [
            #"choose "Which split today?" Push|Pull|Legs +other"#,
        ])
        sleep(3)
        tap(app.buttons["Legs"].firstMatch, pause: 2)
        cut()
    }

    func testPick() {
        play("pick", "Build me a home workout", [
            #"pick "What gear do you have?" Dumbbells|Bench|Bands|"Pull-up bar"|Kettlebell +other max=3"#,
        ])
        sleep(3)
        tap(app.buttons["Dumbbells"].firstMatch)
        tap(app.buttons["Bands"].firstMatch)
        tap(app.buttons["Kettlebell"].firstMatch)
        tap(app.buttons["Done"].firstMatch, pause: 2)
        cut()
    }

    func testForm() {
        play("form", "Check me in", [
            #"form "Daily check-in" mood:1-5 "Trained today":yes split:Push|Pull|Legs submit="Log it""#,
        ])
        sleep(3)
        let mood = app.sliders.firstMatch
        if mood.waitForExistence(timeout: 5), mood.isHittable { mood.adjust(toNormalizedSliderPosition: 0.8); sleep(1) }
        tap(app.switches.firstMatch)
        tap(app.buttons["Pull"].firstMatch)
        tap(app.buttons["Log it"].firstMatch, pause: 2)
        cut()
    }

    func testGallery() {
        play("gallery", "Show me the studio shoot", [
            #"gallery "Studio shoot" /demo/g1.jpg|"On the wheel" /demo/g2.jpg /demo/g3.jpg /demo/g4.jpg layout=grid +pick max=2 submit="Use these""#,
        ])
        sleep(4)
        let picks = app.buttons.matching(NSPredicate(format: "label == %@", "Pick"))
        tap(picks.element(boundBy: 0))
        tap(picks.element(boundBy: 1))
        tap(app.buttons["Use these"].firstMatch, pause: 2)
        cut()
    }

    func testCompare() {
        play("compare", "What did you change in the living room?", [
            #"compare /demo/before_room.jpg /demo/after_room.jpg "Living room" notes="Sage wall|Bigger plant|Jute rug" hl=45,4,53,45|19,25,20,54|16,78,83,21 labels=Old|New +pick"#,
        ])
        sleep(4)
        tap(app.buttons["Side by side"].firstMatch, pause: 3)
        tap(app.buttons["New"].firstMatch, pause: 2)
        cut()
    }

    func testChart() {
        play("chart", "How is my weight trending?", [
            "say Down 2.3 pounds this week, right on plan.",
            #"stat 178.9lb Weight delta=-2.3 spark=181.2|180.6|179.8|178.9 good=down sub="this week""#,
            #"chart line "Weight" x=Mon|Tue|Wed|Thu y=180|179|178.5|178.9 y2=180|179.5|179|178.5 names=Actual|Plan unit=lb"#,
        ], agent: "coach")
        sleep(6)
        cut()
    }

    func testStoryboard() {
        play("storyboard", "Draft the launch reel", [
            #"storyboard "Launch reel" /demo/s1.jpg|Hook /demo/s2.jpg|Problem /demo/s3.jpg|CTA +reorder"#,
        ])
        sleep(4)
        tap(app.buttons["Move frame 1 down"].firstMatch)
        tap(app.buttons["Save order"].firstMatch, pause: 2)
        cut()
    }

    func testCalc() {
        play("calc", "Why does 45 degrees go farthest?", [
            #"calc "How far does it fly?" f="R = v^2*sin(2*a)/g" v=5-40@20m/s a=0-90@30deg g=9.81m/s^2 plot=a unit=m"#,
        ])
        sleep(4)
        // The angle, 30 degrees to 45 (the peak) to 70.
        let angle = app.sliders["a"].firstMatch
        if angle.waitForExistence(timeout: 5), angle.isHittable {
            angle.adjust(toNormalizedSliderPosition: 0.5)
            sleep(2)
            angle.adjust(toNormalizedSliderPosition: 0.78)
            sleep(2)
            angle.adjust(toNormalizedSliderPosition: 0.5)
        }
        sleep(1)
        cut()
    }
}
