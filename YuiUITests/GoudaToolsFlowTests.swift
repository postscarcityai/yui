import XCTest

/// Gouda's tools, the whole way (YUI-184): Learn a song from his home chip as one
/// full-screen plan with the questions last and one Send, the song landing on his
/// Chords page ready to play, the speed and a hard bar changed in place (patches, no
/// new page), the click run past 10 seconds and stopped so the practice logs itself,
/// and a beat started on the Looper. Then the app is killed and relaunched and his
/// pages are still there, the unsent beat too, and five trips to another agent and
/// back keep them. Chris (Sep 28): the 0.5.0 switch-agent crash hid behind the demo
/// account's memory, so the beat lives in UserDefaults and this test only passes if
/// it comes back from there. Every agent reply is runtime/src/music.ts's, verbatim.
/// Demo account, no network. `YUI_SHOTS=<dir>` saves screenshots.
final class GoudaToolsFlowTests: XCTestCase {
    /// runtime: "Learn a song" (learnBody).
    static let learn = #"""
Let's learn one.
```yui
plan@learn "Learn a song" submit="Let's play"
page "Play along" body="Pick a song or paste its chords. The chords land on buttons, the click counts you in, and your keys stay in its key. Slow it down or loop the hard bar any time."
choose@song "Which song?" "Stand By Me"|"Three Little Birds"|"Let It Be"|"Knockin' on Heaven's Door"|"My own chords" +other
form@own "Or paste the chords" name:text chords:long bpm:number
choose@key "What key?" "As written"|"Easiest on guitar"|"Up a step"|"Down a step"
choose@speed "How fast to start?" "Half speed"|"75%"|"Full speed"
```
"""#
    /// runtime: the plan's Send, Stand By Me as written at 75% (lesson + screenLines): Chords drawn again, the rest patched.
    static let learned = #"""
Stand By Me is on your Chords page: 8 bars in A, the click at 89. Tap Start, count four, play.
```yui
>3 clear
>3
card@lesson "Stand By Me" "Key of A, 8 bars. Click at 89, 75% of 118." sub="Learning now" cta="Learn another"
chords@chords "A"|"F#m"|"D"|"E" "Stand By Me" +inline
metronome@click 89 "Stand By Me"
choose@speed "Speed" "Half"|"75%"|"90%"|"Full" body="Now 89 bpm."
choose@bar "Loop a bar" "Whole song"|"Bar 1: A"|"Bar 2: A"|"Bar 3: F#m"|"Bar 4: F#m"|"Bar 5: D"|"Bar 6: E"|"Bar 7: A"|"Bar 8: A" body="Tap the hard one to loop it."
save chords
~keys A major "Keys, in A" +inline
~scale "Scale" "Major"|"Minor"|"Pentatonic"|"Blues" body="A major. Keys outside it stay quiet."
~streak "0 days" "Streak" sub="Practice today and this starts."
~week-min "0 min" "This week" sub="The click logs itself after 10 seconds"
~practice-chart bar "Minutes a day" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=0|0|0|0|0|0|0 unit=min
~next-up "Next: Stand By Me at 89" "Play it through twice. Nail it and I'll speed it up to 100." cta="Log practice"
~recent title="Lately" "Nothing logged yet"
```
"""#
    /// runtime: Half tapped on Chords (patches only).
    static let speed = #"""
Stand By Me at 59 now.
```yui
~lesson "Stand By Me" "Key of A, 8 bars. Click at 59, 50% of 118." sub="Learning now" cta="Learn another"
~chords "A"|"F#m"|"D"|"E" "Stand By Me" +inline
~click 59 "Stand By Me"
~speed "Speed" "Half"|"75%"|"90%"|"Full" body="Now 59 bpm."
~bar "Loop a bar" "Whole song"|"Bar 1: A"|"Bar 2: A"|"Bar 3: F#m"|"Bar 4: F#m"|"Bar 5: D"|"Bar 6: E"|"Bar 7: A"|"Bar 8: A" body="Tap the hard one to loop it."
~streak "0 days" "Streak" sub="Practice today and this starts."
~week-min "0 min" "This week" sub="The click logs itself after 10 seconds"
~practice-chart bar "Minutes a day" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=0|0|0|0|0|0|0 unit=min
~next-up "Next: Stand By Me at 59" "Play it through twice. Nail it and I'll speed it up to 71." cta="Log practice"
~recent title="Lately" "Nothing logged yet"
```
"""#
    /// runtime: Bar 3 tapped on Chords: the chord buttons become that bar and the next (patches only).
    static let bar = #"""
Looping bar 3 of Stand By Me. Stay on it until it's easy.
```yui
~lesson "Stand By Me" "Key of A, 8 bars. Click at 59, 50% of 118." sub="Looping bar 3" cta="Learn another"
~chords "F#m"|"D" "Stand By Me, bar 3" +inline
~click 59 "Stand By Me"
~speed "Speed" "Half"|"75%"|"90%"|"Full" body="Now 59 bpm."
~bar "Loop a bar" "Whole song"|"Bar 1: A"|"Bar 2: A"|"Bar 3: F#m"|"Bar 4: F#m"|"Bar 5: D"|"Bar 6: E"|"Bar 7: A"|"Bar 8: A" body="Bar 3 and the next, over and over."
~streak "0 days" "Streak" sub="Practice today and this starts."
~week-min "0 min" "This week" sub="The click logs itself after 10 seconds"
~practice-chart bar "Minutes a day" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=0|0|0|0|0|0|0 unit=min
~next-up "Next: bar 3 of Stand By Me" "Loop it at 59 until it feels easy, then play the whole song." cta="Log practice"
~recent title="Lately" "Nothing logged yet"
```
"""#
    /// runtime: the click stopped after 12 seconds: a minute logged, Practice patched.
    static let clicked = #"""
Logged 1 minute: Stand By Me.
```yui
~lesson "Stand By Me" "Key of A, 8 bars. Click at 59, 50% of 118." sub="Looping bar 3" cta="Learn another"
~chords "F#m"|"D" "Stand By Me, bar 3" +inline
~click 59 "Stand By Me"
~speed "Speed" "Half"|"75%"|"90%"|"Full" body="Now 59 bpm."
~bar "Loop a bar" "Whole song"|"Bar 1: A"|"Bar 2: A"|"Bar 3: F#m"|"Bar 4: F#m"|"Bar 5: D"|"Bar 6: E"|"Bar 7: A"|"Bar 8: A" body="Bar 3 and the next, over and over."
~streak "1 day" "Streak" sub="Days in a row. Keep it going."
~week-min "1 min" "This week" sub="Over 1 day"
~practice-chart bar "Minutes a day" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=1|0|0|0|0|0|0 unit=min
~next-up "Next: bar 3 of Stand By Me" "Loop it at 59 until it feels easy, then play the whole song." cta="Log practice"
~recent title="Lately" "09/28 1 min, Stand By Me"
```
"""#

    private var appearance = "light"
    private let tmp = FileManager.default.temporaryDirectory

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "gouda-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "gouda-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    /// The one on screen: the chat keeps its own copy under the full screen.
    private func b(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    private func hittable(_ app: XCUIApplication, _ id: String, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if b(app, id).exists, b(app, id).isHittable { return true }
            usleep(300_000)
        }
        return false
    }

    private func text(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 5) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func page(_ app: XCUIApplication, _ n: Int) -> XCUIElement { app.descendants(matching: .any)["stage-screen-\(n)"] }

    /// A button on page `n` by id or label, scrolled up to if it sits below the fold.
    private func on(_ app: XCUIApplication, _ n: Int, _ id: String) -> XCUIElement {
        let q = page(app, n).buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
        for _ in 0..<5 {
            let e = q.allElementsBoundByIndex.first { $0.isHittable } ?? q.firstMatch
            if e.exists, e.isHittable { return e }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -260)))
        }
        return q.allElementsBoundByIndex.first { $0.isHittable } ?? q.firstMatch
    }

    /// The chord buttons on Chords, in order, by their names.
    private func chords(_ app: XCUIApplication) -> [String] {
        // The buttons sit at the top of the page: scroll back up to them (off screen they are not drawn).
        let first = page(app, 3).descendants(matching: .any)["chord-0"]
        for _ in 0..<4 where !(first.exists && first.isHittable) { page(app, 3).swipeDown() }
        let all = page(app, 3).descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chord-'"))
        return all.allElementsBoundByIndex.map { $0.label }
    }

    private func bpm(_ app: XCUIApplication) -> String {
        page(app, 3).descendants(matching: .any)["metronome-bpm"].label
    }

    /// The stage's Next, until `there` (a reply plays a part at a time).
    private func forward(_ app: XCUIApplication, _ there: () -> Bool) {
        for _ in 0..<6 where !there() {
            let next = app.buttons["stage-next"]
            if next.exists, next.isHittable, next.isEnabled { next.tap() } else { return }
        }
    }

    private func write(_ name: String, _ object: Any) throws -> String {
        let url = tmp.appending(path: name)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url.path
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiAgent", "gouda", "-appearance", appearance] + args
        app.launch()
        return app
    }

    /// The thread as the server hands it back on open: the home, then every row the flow wrote.
    /// The beat on the Looper is not in it (it was never sent), so it can only come from UserDefaults.
    private func rows() -> [[String: Any]] {
        func row(_ id: String, _ sender: String, _ body: String, _ at: Int, kind: String = "text", meta: [String: Any]? = nil) -> [String: Any] {
            var r: [String: Any] = ["id": id, "sender": sender, "kind": kind, "body": body,
                                    "created_at": String(format: "2026-09-28T16:00:%02d+00:00", at)]
            if let meta { r["meta"] = meta }
            return r
        }
        func tap(_ id: String, _ preset: String, _ value: [String: Any], _ echo: String) -> [String: Any] {
            ["id": id, "preset": preset, "value": value, "echo": echo]
        }
        return [
            row("home-gouda", "agent", Self.homeRow, 0, meta: ["native": "home"]),
            row("u1", "user", "Learn a song", 1),
            row("a1", "agent", Self.learn, 2),
            row("e1", "user", "[yui] learn plan", 3, kind: "event",
                meta: tap("learn", "plan", ["plan": ["song": "Stand By Me", "key": "As written", "speed": "75%"]], "Stand By Me")),
            row("a2", "agent", Self.learned, 4),
            row("e2", "user", "[yui] speed choose", 5, kind: "event", meta: tap("speed", "choose", ["choice": "Half"], "Half")),
            row("a3", "agent", Self.speed, 6),
            row("e3", "user", "[yui] bar choose", 7, kind: "event", meta: tap("bar", "choose", ["choice": "Bar 3: F#m"], "Bar 3: F#m")),
            row("a4", "agent", Self.bar, 8),
            row("e4", "user", "[yui] click metronome", 9, kind: "event",
                meta: tap("click", "metronome", ["bpm": 59, "beats": 4, "sub": 1, "seconds": 12], "Practiced 12 s at 59 BPM")),
            row("a5", "agent", Self.clicked, 10),
        ]
    }

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private func run(_ look: String) throws {
        appearance = look
        let log = tmp.appending(path: "yui-gouda-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let replies = try write("yui-gouda-replies.json", [Self.learn, Self.learned, Self.speed, Self.bar, Self.clicked])
        var app = launch(["-yuiDemoHome", "-yuiDemoReplyFile", replies, "-yuiDemoReplyTaps", "-yuiDemoReplyAfter", "0.6",
                          "-yuiEventLog", log, "-yuiTicksReset"])
        let events = { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }

        // His home: Learn a song is a chip.
        let chip = app.buttons["home-chip-learn"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "no Learn a song chip on Gouda's home")
        shot("1-home")
        chip.tap()

        // One full-screen plan: what happens first, then the song, the key and the speed, one Send.
        XCTAssertTrue(text(app, "learn one", timeout: 15), "Gouda never answered")
        forward(app) { self.text(app, "Play along", timeout: 1) }
        XCTAssertTrue(text(app, "Play along", timeout: 5), "the plan never opened")
        shot("2-plan-open")
        forward(app) { self.hittable(app, "Stand By Me", timeout: 1) }
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no one Send under the questions")
        XCTAssertEqual(send.label, "Let's play")
        XCTAssertFalse(send.isEnabled, "Send before any answer")
        for a in ["Stand By Me", "As written", "75%"] {
            XCTAssertTrue(hittable(app, a, timeout: 2) || { app.swipeUp(); return self.hittable(app, a, timeout: 2) }(), "no \(a)")
            b(app, a).tap()
            if a == "As written" { shot("3-questions") }
        }
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isEnabled, "Send still off with every question answered")
        shot("4-send")
        send.tap()
        let sent = events().split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0["plan"] as? [String: Any] }.last
        let p = try XCTUnwrap(sent, "no {plan} event: \(events())")
        XCTAssertEqual(p["song"] as? String, "Stand By Me")
        XCTAssertEqual(p["key"] as? String, "As written")
        XCTAssertEqual(p["speed"] as? String, "75%")

        // The song lands on Chords, ready to play: its chords on buttons, the click at 75%.
        XCTAssertTrue(text(app, "is on your Chords page", timeout: 20), "the lesson never landed")
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        app.goToScreen(3)
        XCTAssertTrue(page(app, 3).waitForExistence(timeout: 5), "no Chords page")
        XCTAssertTrue(page(app, 3).staticTexts["Key of A, 8 bars. Click at 89, 75% of 118."].waitForExistence(timeout: 5),
                      "Chords does not hold the song")
        XCTAssertEqual(chords(app), ["A", "F#m", "D", "E"], "the song's chords are not on the buttons")
        XCTAssertEqual(bpm(app), "89 beats per minute")
        shot("5-chords")

        // Slow it down: patched in place, the chords stay.
        on(app, 3, "Half").tap()
        XCTAssertTrue(text(app, "at 59 now", timeout: 10), "the speed never came back")
        XCTAssertTrue(events().contains("\"choice\":\"Half\""), "the speed tap sent nothing")
        let slowed = NSPredicate { _, _ in self.bpm(app) == "59 beats per minute" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: slowed, object: nil)], timeout: 5), .completed,
                       "the click is still at \(bpm(app))")
        XCTAssertEqual(chords(app), ["A", "F#m", "D", "E"])
        waitScreen(app, 3, "a patch moved the person off Chords")

        // Loop the hard bar: the buttons become that bar and the next.
        on(app, 3, "Bar 3: F#m").tap()
        XCTAssertTrue(text(app, "Looping bar 3", timeout: 10), "the bar never came back")
        let looped = NSPredicate { _, _ in self.chords(app) == ["F#m", "D"] }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: looped, object: nil)], timeout: 5), .completed,
                       "the chord buttons are \(chords(app))")
        shot("6-bar-looped")

        // Play along: the click past 10 seconds, then Stop, logs the practice.
        on(app, 3, "metronome-play").tap()
        sleep(11)
        shot("7-click-playing")
        on(app, 3, "metronome-play").tap()
        XCTAssertTrue(text(app, "Logged 1 minute", timeout: 10), "the practice never logged")
        XCTAssertTrue(events().contains("\"seconds\":"), "Stop sent no seconds: \(events())")
        app.goToScreen(5)
        XCTAssertTrue(page(app, 5).staticTexts["1 day"].waitForExistence(timeout: 5), "Practice has no streak")
        XCTAssertTrue(page(app, 5).staticTexts["09/28 1 min, Stand By Me"].waitForExistence(timeout: 3), "Practice has no log row")
        shot("8-practice")

        // Start a beat on the Looper: a step and the tempo, nothing sent yet.
        app.goToScreen(2)
        let before = events().split(separator: "\n").count
        let cell = on(app, 2, "loop-cell-1-0")
        XCTAssertEqual(cell.value as? String, "off")
        cell.tap()
        XCTAssertEqual(on(app, 2, "loop-cell-1-0").value as? String, "on")
        on(app, 2, "loop-faster").tap()
        XCTAssertTrue(page(app, 2).staticTexts["94 BPM"].waitForExistence(timeout: 3), "the tempo did not move")
        XCTAssertEqual(events().split(separator: "\n").count, before, "an edit on the Looper sent something")
        let snare = page(app, 2).descendants(matching: .any)["loop-cell-1-0"]
        for _ in 0..<3 where !snare.isHittable { page(app, 2).swipeDown() }
        shot("9-looper-beat")

        // Killed: the thread comes back from the server's rows, the beat from the phone.
        app.terminate()
        let thread = try write("yui-gouda-rows.json", rows())
        app = launch(["-yuiDemoHome", "-yuiThreadRows", thread, "-yuiEventLog", log])
        XCTAssertTrue(app.buttons["home-chip-learn"].waitForExistence(timeout: 15), "no home after the relaunch")
        XCTAssertTrue(text(app, "Nothing waiting on you"), "his pages' pickers read as waiting on you")
        try kept(app, "after the relaunch")
        shot("10-relaunched")

        // Five trips to another agent and back (the 0.5.0 crash path): up, and his pages kept.
        for i in 1...5 {
            if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
            XCTAssertTrue(app.pickAgent("Yui"), "could not switch to Yui (trip \(i))")
            XCTAssertTrue(app.pickAgent("Gouda"), "could not switch back to Gouda (trip \(i))")
            XCTAssertEqual(app.state, .runningForeground, "the app died on trip \(i)")
        }
        let pill = [app.buttons["stage-agents"], app.buttons["record-agents"]].first { $0.exists } ?? app.buttons["stage-agents"]
        XCTAssertTrue(pill.label.contains("Gouda"), "not back on Gouda: \(pill.label)")
        try kept(app, "after 5 switches")
        shot("11-after-switches")
    }

    /// His pages as the flow left them: the looped bar at 59 on Chords, the minute on Practice, the beat on the Looper.
    private func kept(_ app: XCUIApplication, _ when: String) throws {
        app.goToScreen(3)
        XCTAssertTrue(page(app, 3).staticTexts["Looping bar 3"].waitForExistence(timeout: 8), "Chords lost the song \(when)")
        XCTAssertEqual(chords(app), ["F#m", "D"], "Chords lost the looped bar \(when)")
        XCTAssertEqual(bpm(app), "59 beats per minute", "the click lost its speed \(when)")
        app.goToScreen(5)
        XCTAssertTrue(page(app, 5).staticTexts["1 day"].waitForExistence(timeout: 5), "Practice lost the streak \(when)")
        app.goToScreen(2)
        XCTAssertEqual(on(app, 2, "loop-cell-1-0").value as? String, "on", "the Looper lost the unsent beat \(when)")
        XCTAssertTrue(page(app, 2).staticTexts["94 BPM"].exists, "the Looper lost its tempo \(when)")
    }

    /// Gouda's home row, as yui-agents writes it (runtime/profiles/gouda/home.yui).
    static let homeRow = #"""
```yui
menu shortcut@tune "Tune up" say="Tune my guitar"
menu shortcut@jam "Jam" say="Make me a beat to jam on"
menu shortcut@log "Log practice" say="Log practice"
menu shortcut@learn "Learn a song" say="Learn a song"
>2
loop@looper 92 "Lazy Sunday" p=x...x...|..x...x.|........|x.x.x.x. +inline
choose@sessions "Open a beat" "Lazy Sunday"|"Boom bap"|"Four on the floor"|"Rock backbeat"|"One drop" body="Send on the looper saves your version."
save looper
>3
card@lesson "Learn a song" "Pick a song or paste its chords. The click counts you in and your keys stay in key." cta="Learn a song"
chords@chords C I-V-vi-IV "Chords" +inline
metronome@click 90 "Click"
save chords
>4
keys@keys C major "Keys" +inline
choose@scale "Scale" "Major"|"Minor"|"Pentatonic"|"Blues" body="C major. Keys outside it stay quiet."
save keys
>5
stat@streak "0 days" "Streak" sub="Practice today and this starts."
stat@week-min "0 min" "This week" sub="The click logs itself after 10 seconds"
chart@practice-chart bar "Minutes a day" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=0|0|0|0|0|0|0 unit=min
card@next-up "Next: ten minutes" "Pick a song on Chords and play along with the click. It all counts toward your streak." cta="Log practice"
list@recent title="Lately" "Nothing logged yet"
save practice
```
"""#
}
