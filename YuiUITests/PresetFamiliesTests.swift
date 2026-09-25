import XCTest

/// Native versions of the YUI-16/17/18 presets (YUI-19): media, data and
/// science, learn and plan. Each test streams one reply on the demo account,
/// taps through it and checks the events that went back. Screenshots go to
/// `YUI_SHOTS` when set, and always into the result bundle.
final class PresetFamiliesTests: XCTestCase {
    private var app: XCUIApplication!
    private var log = ""
    private var tag = ""

    private func launch(_ tag: String, _ lines: [String], appearance: String = "light") {
        self.tag = tag
        log = FileManager.default.temporaryDirectory.appending(path: "yui19-\(tag).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiThemeDemo", lines.joined(separator: "\\n"), "-yuiEventLog", log]
        app.launch()
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(tag)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    /// Events so far, as parsed JSON objects.
    private func events() -> [[String: Any]] {
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func attachEvents() {
        let a = XCTAttachment(string: (try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
        a.name = "\(tag)-events.jsonl"
        a.lifetime = .keepAlways
        add(a)
    }

    /// Waits for an event from `preset` that has `key`.
    @discardableResult
    private func waitEvent(_ preset: String, _ key: String, timeout: TimeInterval = 8) -> [String: Any]? {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if let e = events().last(where: { $0["preset"] as? String == preset && $0[key] != nil }) { return e }
            usleep(250_000)
        }
        XCTFail("no \(preset) event with \(key)")
        return nil
    }

    /// Back up the chat (it follows the stream to the last line) until `e` is fully in view.
    private func scrollBackTo(_ e: XCUIElement, max: Int = 12) {
        var n = 0
        while !(ready(e) && e.frame.minY > 160), n < max { app.swipeDown(velocity: .slow); n += 1 }
    }

    /// Ready to tap: on screen with a real frame (asking a lazy, zero-frame element
    /// whether it is hittable fails the test outright).
    private func ready(_ e: XCUIElement) -> Bool {
        e.exists && !e.frame.isEmpty && e.frame.minY > 100 && e.frame.maxY < app.frame.maxY - 90 && e.isHittable
    }

    /// Scroll the chat back in the avatar gutter: a swipe down the middle lands on
    /// the compare slider, which takes the drag and the chat never moves.
    private func gutterSwipeDown() {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.3))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.75)))
    }

    private func scrollTo(_ e: XCUIElement, max: Int = 8) {
        var n = 0
        while !ready(e), n < max { app.swipeUp(velocity: .slow); n += 1 }
    }

    // MARK: media

    func testMedia() throws {
        launch("media", [
            #"gallery "Studio shoot" /demo/g1.jpg|"On the wheel" /demo/g2.jpg /demo/g3.jpg /demo/g4.jpg layout=grid +pick max=2 submit="Use these""#,
            #"compare /demo/before_room.jpg /demo/after_room.jpg "Living room" notes="Sage wall|Bigger plant|Jute rug" hl=45,4,53,45|19,25,20,54|16,78,83,21 labels=Old|New +pick"#,
            #"storyboard "Launch reel" /demo/s1.jpg|Hook /demo/s2.jpg|Problem /demo/s3.jpg|CTA +reorder"#,
            #"gallery "This week" /demo/g1.jpg|"First cut" /demo/g2.jpg /demo/g3.jpg layout=row"#,
        ])
        let picks = app.buttons.matching(NSPredicate(format: "label == %@", "Pick"))
        // The chat follows the stream to the last line; go back up to the grid.
        XCTAssertTrue(app.staticTexts["This week"].waitForExistence(timeout: 20), "the reply never finished")
        var n = 0
        while !ready(picks.firstMatch), n < 10 { gutterSwipeDown(); n += 1 }
        XCTAssertTrue(picks.firstMatch.exists, "the gallery never arrived")
        sleep(3)
        shot("1-gallery-grid")

        // +pick: the first and third, then submit.
        let tiles = picks.count
        picks.element(boundBy: 0).tap()
        // Wait for the first to read "Picked", or the next tap lands on the stale list.
        let relabeled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", tiles - 1), object: picks)
        XCTAssertEqual(XCTWaiter.wait(for: [relabeled], timeout: 3), .completed, "the first pick never showed")
        picks.element(boundBy: 1).tap() // the third tile: the first is now "Picked"
        app.buttons["Use these"].tap()
        let picked = waitEvent("gallery", "picked")
        XCTAssertEqual(picked?["picked"] as? [Int], [0, 2])
        shot("2-gallery-picked")

        // Tap a tile: full screen, {open, index}.
        app.otherElements["On the wheel"].firstMatch.tap()
        let open = waitEvent("gallery", "open")
        XCTAssertEqual(open?["index"] as? Int, 0)
        sleep(2)
        shot("3-gallery-viewer")
        app.buttons["Close"].tap()

        // compare: switch modes, A/B pick.
        let side = app.buttons["Side by side"]
        scrollTo(side)
        sleep(2)
        shot("4-compare-slider")
        side.tap()
        sleep(1)
        shot("5-compare-side")
        let new = app.buttons["New"]
        scrollTo(new)
        new.tap()
        XCTAssertEqual(waitEvent("compare", "choice")?["choice"] as? String, "New")

        // storyboard: comment on the first frame, then move it down and save the order.
        let comment = app.textFields["Comment on this frame"].firstMatch
        scrollTo(comment)
        comment.tap()
        comment.typeText("Faster cut\n")
        let c = waitEvent("storyboard", "comment")
        XCTAssertEqual(c?["frame"] as? Int, 0)
        XCTAssertEqual(c?["comment"] as? String, "Faster cut")
        sleep(1) // the keyboard goes down
        let down = app.buttons["Move frame 1 down"]
        scrollTo(down)
        down.tap()
        let save = app.buttons["Save order"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        sleep(1)
        shot("6-storyboard-reordered")
        save.tap()
        XCTAssertEqual(waitEvent("storyboard", "order")?["order"] as? [Int], [1, 0, 2])
        app.swipeUp()
        sleep(2)
        shot("7-gallery-row")
        attachEvents()
    }

    // MARK: data and science

    func testScience() throws {
        launch("science", [
            #"chart bar "Yield" x=None|Low|High y=2.1±0.3|3.4±0.4|4.8±0.7 y2=2.0|3.1|4.0 names=Tomato|Pepper unit=kg"#,
            #"stat 178.9lb Weight delta=-2.3 spark=181.2|180.6|179.8|178.9 good=down sub="this week""#,
            #"math caption="Bayes rule" P(A \mid B) = \frac{P(B \mid A)\,P(A)}{P(B)}"#,
            #"step title="Solve for t" "Start from rest" $ d = \tfrac{1}{2} g t^2"#,
            #"step "Divide by g/2" $ t^2 = \frac{2d}{g}"#,
            #"calc "How far does it fly?" f="R = v^2*sin(2*a)/g" v=5-40@20m/s a=0-90@30deg g=9.81m/s^2 plot=a unit=m"#,
            #"chart donut "Where the week went" x="Deep work"|Meetings|Email y=14|9|6 unit=h"#,
        ])
        XCTAssertTrue(app.staticTexts["Where the week went"].waitForExistence(timeout: 25), "the reply never finished")
        let chart = app.descendants(matching: .any)["yl-chart"].firstMatch
        scrollBackTo(chart)
        XCTAssertTrue(chart.exists, "no chart element")
        sleep(2)
        shot("1-chart-stat")

        // Tap the chart: {point: {series, index, x, y, name}}.
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)).tap()
        let point = waitEvent("chart", "point")?["point"] as? [String: Any]
        XCTAssertNotNil(point?["index"])
        XCTAssertNotNil(point?["name"], "two series should name the point")
        sleep(1)
        shot("2-chart-point")

        // Table view of the same data.
        app.buttons["Table"].firstMatch.tap()
        sleep(1)
        shot("3-chart-table")

        // Steps: Next, then Done.
        let next = app.buttons["Next"]
        scrollTo(next)
        sleep(1)
        shot("4-math-step")
        next.tap()
        XCTAssertEqual(waitEvent("step", "done")?["index"] as? Int, 0)
        sleep(1) // the next step springs in and pushes the buttons down
        app.buttons["Done"].tap()
        let last = waitEvent("step", "last")
        XCTAssertEqual(last?["index"] as? Int, 1)

        // calc: the angle slider to 45 degrees sends the range at its peak.
        let slider = app.sliders["a"]
        scrollTo(slider)
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let calc = waitEvent("calc", "result")
        let values = calc?["values"] as? [String: Double] ?? [:]
        // Degrees stay degrees in the event; the formula got radians.
        let a = values["a"] ?? .nan
        XCTAssertEqual(values["v"], 20)
        XCTAssertEqual(values["g"], 9.81)
        XCTAssertNotEqual(a, 30, "the slider did not move")
        XCTAssertEqual(calc?["result"] as? Double ?? 0, 400 * sin(2 * a * .pi / 180) / 9.81, accuracy: 0.001)
        sleep(1)
        shot("5-calc")
        app.swipeUp()
        sleep(1)
        shot("6-donut")
        attachEvents()
    }

    /// A card with `url=` is a link (TestFlight feedback AHbFq_lhBMRFGDoCfVzMf4A):
    /// its button opens Safari and sends nothing; a card without one still emits `{cta}`.
    func testCardLink() throws {
        launch("card-link", [
            #"card "Yui 65.1" sub="Test build" body="Tap to install" cta=Install url=https://www.yuigui.com/install.html"#,
            #"card "Sunday plan" body="3 sessions" cta=Start"#,
        ])
        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "the reply never finished")
        let install = app.buttons["Install"]
        XCTAssertTrue(install.exists)
        sleep(1)
        shot("1-cards")

        start.tap()
        XCTAssertEqual(waitEvent("card", "cta")?["cta"] as? String, "Start")

        install.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "Install did not open Safari")
        let ctas = events().filter { $0["preset"] as? String == "card" }.compactMap { $0["cta"] as? String }
        XCTAssertEqual(ctas, ["Start"], "the link button sent something to the chat")
        attachEvents()
    }

    func testScienceDark() throws {
        launch("science-dark", [
            #"chart line "Weight" x=Mon|Tue|Wed|Thu y=180|179|178.5|178.9 y2=180|179.5|179|178.5 names=Actual|Plan unit=lb"#,
            #"stat 37.4degC Incubator delta=0.2 sub="target 37.0""#,
            #"table@wk Weigh-ins Day|Weight "Mon|181.2" "Tue|180.6" "Wed|179.8" units=|lb +sort"#,
            #"chart line data=wk x=Day y=Weight"#,
        ], appearance: "dark")
        XCTAssertTrue(app.staticTexts["Weight"].waitForExistence(timeout: 15))
        sleep(2)
        shot("1-line-stat")
        app.buttons["Sort by Weight"].firstMatch.tap()
        XCTAssertEqual(waitEvent("table", "sort")?["dir"] as? String, "asc")
        app.swipeUp()
        sleep(1)
        shot("2-table-bound-chart")
        attachEvents()
    }

    // MARK: learn and plan

    func testFlows() throws {
        launch("flows", [
            #"deck "How mRNA vaccines work" +notes"#,
            #"page "How mRNA vaccines work" /demo/mrna1.jpg notes="A set of instructions wrapped in a tiny bubble of fat.""#,
            #"page "1. Delivery" /demo/mrna2.jpg body="Lipid nanoparticles carry the mRNA into arm muscle cells.""#,
            #"page "2. The immune system learns" points="Spike pieces show on the cell|B cells make antibodies|T cells learn the shape""#,
            #"choose "Where is the mRNA read?" Nucleus|Cytoplasm|"The blood" answer=Cytoplasm why="Ribosomes in the cytoplasm read it.""#,
            "end",
            #"plan@site "New website""#,
            #"choose@kind "What kind of site?" Portfolio|Shop|"Local business""#,
            #"pick@pages "Which pages?" Home|About|Pricing|Contact"#,
            "end",
            #"project "Kiln & Co. website" status=Planning progress=40 facts="Pages: Home, Classes|Launch: Dec 1" next="Pick a template" cta="Reopen the plan""#,
            #"narrate "What changed on the site""#,
            #"compare /demo/site_before_hero.jpg /demo/site_after_hero.jpg "1. The hero" hl=3,28,50,46 say="The new headline says what you will make.""#,
            #"card "2. Classes" "A wall of text became three cards with prices.""#,
            "end",
        ])
        // The deck opens on the stage.
        let close = app.buttons["Close full screen"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "the deck did not take the stage")
        sleep(3)
        shot("1-deck-cover")
        let next = app.buttons["Next page"]
        next.tap(); sleep(1)
        shot("2-deck-split")
        next.tap(); sleep(1)
        shot("3-deck-points")
        next.tap(); sleep(1)
        // The deck is done (once) when every page is seen and every question answered.
        app.buttons["Cytoplasm"].tap()
        XCTAssertEqual(waitEvent("choose", "correct")?["correct"] as? Bool, true)
        sleep(1)
        shot("4-deck-quiz")
        let done = waitEvent("deck", "done")
        XCTAssertEqual(done?["pages"] as? Int, 4)
        XCTAssertEqual(done?["score"] as? Int, 1)
        XCTAssertEqual(done?["of"] as? Int, 1)
        // Answers stay open: another try is graded too.
        app.buttons["Nucleus"].tap()
        sleep(1)
        let retry = events().last { $0["preset"] as? String == "choose" }
        XCTAssertEqual(retry?["correct"] as? Bool, false)
        XCTAssertEqual(retry?["changed"] as? Bool, true)

        // plan: on the same stage under the deck (YUI-51). choose moves on by
        // itself, pick, review, submit, and the stage closes on its own.
        let shop = app.buttons["Shop"]
        scrollTo(shop)
        sleep(1)
        shot("5-plan-step1")
        shop.tap()
        let home = app.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        sleep(1)
        home.tap()
        app.buttons["Contact"].tap()
        app.buttons["Done"].tap()
        XCTAssertFalse(events().contains { $0["preset"] as? String == "pick" }, "a plan member sent its own event")
        app.buttons["Review"].tap()
        sleep(1)
        shot("6-plan-review")
        app.buttons["Send"].tap()
        let plan = waitEvent("plan", "plan")?["plan"] as? [String: Any]
        XCTAssertEqual(plan?["kind"] as? String, "Shop")
        XCTAssertEqual(plan?["pages"] as? [String], ["Home", "Contact"])
        XCTAssertTrue(close.waitForNonExistence(timeout: 4) || !close.isHittable, "sending the plan did not close the stage")
        sleep(1)
        shot("7-plan-sent")

        // project: the button sends {cta}.
        let cta = app.buttons["Reopen the plan"]
        scrollTo(cta)
        cta.tap()
        XCTAssertEqual(waitEvent("project", "cta")?["cta"] as? String, "Reopen the plan")

        // narrate: play, it speaks each step and finishes.
        let play = app.buttons["Play"]
        scrollTo(play)
        sleep(1)
        shot("8-narrate")
        play.tap()
        XCTAssertNotNil(waitEvent("narrate", "played"))
        sleep(2)
        shot("9-narrate-speaking")
        let finished = waitEvent("narrate", "done", timeout: 40)
        XCTAssertEqual(finished?["steps"] as? Int, 2)
        attachEvents()
    }

    /// YUI-51: findings then questions in one full-screen flow, one Send, and
    /// the answers fold back into the chat as the person's own message.
    func testPlanFoldsBack() throws {
        launch("fold", [
            #"say "Here is what the last build fixed, then two picks for next.""#,
            #"plan@review "Build review" submit="Send picks""#,
            #"page "What broke" "Two buttons only took taps on their icon, so the gallery X felt dead and the Done pill hid under a tile." points="Gallery X: now a full 44pt target|Done pill: no tile covers it anymore""#,
            #"page "What is new" "Hold any reply to react. Your reaction goes to the agent as one turn, with the message quoted." points="Six reactions|The badge stays on the bubble""#,
            #"choose@next "What should the composer get next?" Files|"Voice notes as audio" +other"#,
            #"pick@where "Where should it show up first?" "The app"|"The site""#,
        ], appearance: "dark")
        let close = app.buttons["Close full screen"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "the plan did not take the stage")
        XCTAssertTrue(app.staticTexts["What broke"].waitForExistence(timeout: 5))
        sleep(2)
        shot("1-page")
        app.buttons["Next"].tap(); sleep(1)
        XCTAssertTrue(app.staticTexts["What is new"].exists)
        app.buttons["Next"].tap(); sleep(1)
        shot("2-question")
        app.buttons["Files"].tap()
        let appPick = app.buttons["The app"]
        XCTAssertTrue(appPick.waitForExistence(timeout: 3))
        sleep(1)
        appPick.tap()
        app.buttons["The site"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(events().isEmpty || !events().contains { ["choose", "pick"].contains($0["preset"] as? String) },
                      "a plan step sent its own event")
        app.buttons["Review"].tap(); sleep(1)
        shot("3-review")
        app.buttons["Send picks"].tap()

        // One event with every answer, pages not keyed.
        let plan = waitEvent("plan", "plan")?["plan"] as? [String: Any]
        XCTAssertEqual(plan?["next"] as? String, "Files")
        XCTAssertEqual(plan?["where"] as? [String], ["The app", "The site"])
        XCTAssertEqual(plan?.count, 2)
        XCTAssertEqual(events().filter { $0["preset"] as? String == "plan" }.count, 1)

        // The stage closes; the answers are the person's own message.
        XCTAssertTrue(close.waitForNonExistence(timeout: 4) || !close.isHittable, "sending did not close the stage")
        let mine = "What should the composer get next? Files\nWhere should it show up first? The app, The site"
        XCTAssertTrue(app.staticTexts[mine].waitForExistence(timeout: 4), "the answers did not fold back as a message")
        sleep(1)
        shot("4-folded")

        // The record: title and what it held, expands to the pages, reopens the flow.
        let record = app.buttons["Build review, sent, 2 pages, 2 answers"]
        XCTAssertTrue(record.waitForExistence(timeout: 3), "no plan record in the chat")
        record.tap(); sleep(1)
        app.buttons["What broke"].tap(); sleep(1)
        shot("5-record-open")
        app.buttons["Open the flow"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Edit answers"].waitForExistence(timeout: 4), "the reopened flow lost its answers")
        sleep(1)
        shot("6-reopened")
        attachEvents()
    }
}
