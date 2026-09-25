import XCTest

/// The war room, built out (YUI-73): screen 2 with Needs you, Running now, the
/// timeline, Builds, Feedback, the MVP bar and quick links, all from existing
/// presets. A Needs-you answer is a `choose@need-<task id>`: one tap sends
/// {id: need-<task id>, choice}, which the yui plugin (hermes-plugin/yui/needs.py)
/// writes onto the card. The yui profile's yui_war_room.py --out FILE makes the
/// live screen; pass it as TEST_RUNNER_YUI_WAR_ROOM=FILE (and the answer to tap
/// as TEST_RUNNER_YUI_WAR_ROOM_TAP, its card as TEST_RUNNER_YUI_WAR_ROOM_NEED).
/// Without them the test draws the sample below. Screenshots go to `YUI_SHOTS`.
final class WarRoomTests: XCTestCase {
    private var app: XCUIApplication!
    private var log = ""
    private var tag = ""

    static let sample = [
        ">2",
        "clear",
        #"stat 2 "Needs you" sub="cards waiting on your answer""#,
        #"card "YUI-54: drawer mocks for your pick" sub="Answer in chat" tag=YUI-54"#,
        #"choose@need-t_049464c4 "YUI-60: Pick a direction for games in lines" "a: board kit"|"b: state machine as data"|"c: sandboxed script"|"Park it""#,
        #"card "The war room, built out" "Panels drafted, tests next" tag=YUI-73 sub="APP lane · beat 2m ago""#,
        #"card "WEB lane" sub="Idle""#,
        #"card "SITE lane" sub="Idle""#,
        #"card "BIZ lane" sub="Idle""#,
        #"timeline "War room" fold=4 +reorder board=yui"#,
        #"done "Reply to one message" at="Sep 25" tag=YUI-68 https://www.yuigui.com/progress"#,
        #"now "The war room, built out" tag=YUI-73 sub="running 40m""#,
        #"next "Agent controls in the drawer" tag=YUI-70 key=t_9eb3509a"#,
        "end",
        #"card "TestFlight build 64" "Try: Screens 2 to 12; Hold to talk" sub="Ready · Sep 24" cta="What's in it" url=https://www.yuigui.com/changelog"#,
        #"card "Test build 67.1" "Links look like links." sub="Installs by link · Sep 25" cta="Install" url=https://www.yuigui.com/install.html"#,
        #"card "I need to be able to reply to a message" sub="Feedback · fixed on main · Sep 24" tag="YUI-68""#,
        #"stat 95% "MVP shipped" sub="21 of 22 cards · last: YUI-68""#,
        #"card "Go-to-market" sub="Who it's for, the 30-day plan" cta="Open GTM" url=https://www.yuigui.com/business/gtm"#,
        "save war room",
    ]

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// The live screen from the generator's --out file (the lines inside its ```yui fence), else the sample.
    private var lines: [String] {
        guard let path = env["YUI_WAR_ROOM"], let text = try? String(contentsOfFile: path, encoding: .utf8),
              let start = text.range(of: "```yui\n"), let end = text.range(of: "\n```", range: start.upperBound..<text.endIndex)
        else { return Self.sample }
        return text[start.upperBound..<end.lowerBound].split(separator: "\n").map(String.init)
    }

    private func launch(_ tag: String, appearance: String) {
        self.tag = tag
        log = FileManager.default.temporaryDirectory.appending(path: "yui73-\(tag).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               // A straight apostrophe breaks launch-argument quoting on the simulator; the phone never sees one here.
                               "-yuiThemeDemo", lines.joined(separator: "\\n").replacingOccurrences(of: "'", with: "\u{2019}"),
                               "-yuiEventLog", log]
        app.launch()
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(tag)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func events() -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }

    private func has(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Every panel, top to bottom, one screenshot per screenful.
    private func walk(_ appearance: String) {
        XCTAssertTrue(has("Needs you").waitForExistence(timeout: 25), "the war room never drew")
        sleep(6)  // the reply streams in line by line
        shot("1-\(appearance)")
        // The page is lazy: each panel is checked as it scrolls into view.
        var seen = Set<String>()
        let panels = ["Running now": "lane", "Timeline": "War room", "Builds": "TestFlight build",
                      "Install": "Install", "Feedback": "Feedback ·", "MVP": "MVP shipped", "Links": "Open GTM"]
        for i in 2...20 {
            for (name, label) in panels where has(label).exists { seen.insert(name) }
            if seen.count == panels.count && app.buttons["Open GTM"].isHittable { break }
            app.swipeUp(velocity: .slow)
            sleep(1)
            shot("\(i)-\(appearance)")
        }
        XCTAssertEqual(seen, Set(panels.keys), "missing panels: \(Set(panels.keys).subtracting(seen))")
    }

    func testWarRoomLight() throws {
        launch("warroom", appearance: "light")
        walk("light")
    }

    func testWarRoomDark() throws {
        launch("warroom", appearance: "dark")
        walk("dark")
    }

    /// One tap on a Needs-you answer sends one event named by the card's task id.
    func testOneTapAnswer() throws {
        let answer = env["YUI_WAR_ROOM_TAP"] ?? "Park it"
        let need = env["YUI_WAR_ROOM_NEED"] ?? "t_049464c4"
        launch("answer", appearance: "light")
        let button = app.buttons[answer]
        XCTAssertTrue(button.waitForExistence(timeout: 25), "no \(answer) button on the war room")
        sleep(6)  // the reply streams in line by line
        button.tap()
        sleep(1)
        shot("tapped")
        let ev = events()
        XCTAssertTrue(ev.contains(#""id":"need-\#(need)""#) && ev.contains(#""preset":"choose""#), "wrong event: \(ev)")
        XCTAssertTrue(ev.contains(#""choice":"\#(answer)""#), "the answer is not in the event: \(ev)")
        XCTAssertEqual(ev.split(separator: "\n").count, 1, "one tap, one event: \(ev)")
    }
}
