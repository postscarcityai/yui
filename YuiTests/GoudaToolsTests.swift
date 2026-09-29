import XCTest
import YuiLines
import YuiSound
@testable import Yui

/// Gouda's tools in the app (YUI-184): the Looper's unsent beat kept on the phone
/// (UserDefaults per agent and looper, the real path a relaunch reads; Chris, Sep 28:
/// the 0.5.0 crash hid behind the demo account's memory), and his pages as the
/// runtime's replies leave them: a song on Chords, the speed and a hard bar patched
/// in place, the practice logged, a beat saved and back on the Looper. No demo store.
@MainActor
final class GoudaToolsTests: XCTestCase {
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
    /// runtime: Send on the Looper page (saveBody).
    static let take = #"""
```yui
plan@keep "Save it" submit=Save
page "Your beat" body="92 bpm, 8 steps. Kick, snare and hat."
form@name "Name it" name:text!
choose@then "Then?" "Keep it on my Looper"|"Just save it"
```
"""#
    /// runtime: the save plan's Send, Night drive, kept on the Looper (patches only).
    static let saved = #"""
Saved Night drive. It's on your Looper.
```yui
~looper 92 "Night drive" p=x...x...|..x...x.|........|x.x.x.x. +inline
~sessions "Open a beat" "Night drive"|"Lazy Sunday"|"Boom bap"|"Four on the floor"|"Rock backbeat"|"One drop" body="1 saved. Send on the looper saves another."
```
"""#

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "yui.tests.loops")
        defaults.removePersistentDomain(forName: "yui.tests.loops")
    }

    private static let at = ISO8601DateFormatter().string(from: .now)

    private func row(_ id: String, _ sender: String, _ body: String, kind: String = "text", meta: YLValue? = nil) -> ThreadRow {
        ThreadRow(id: id, sender: sender, body: body, kind: kind, meta: meta, createdAt: Self.at)
    }

    private func tap(_ id: String, _ preset: String, _ value: [String: YLValue], echo: String) -> ThreadRow {
        row("e-\(id)-\(value.count)", "user", "[yui] \(id) \(preset)", kind: "event",
            meta: .object(["id": .string(id), "preset": .string(preset), "value": .object(value), "echo": .string(echo)]))
    }

    private var home: ThreadRow {
        row("home-gouda", "agent", AgentStore.demoHome["gouda"]!, meta: .object(["native": .string("home")]))
    }

    /// Learn a song, its Send, then as many of Half, Bar 3 and the click as asked for.
    private func learned(_ after: Int = 0) -> ChatStore {
        var rows = [home, row("u1", "user", "Learn a song"), row("a1", "agent", Self.learn),
                    tap("learn", "plan", ["plan": .object(["song": .string("Stand By Me"), "key": .string("As written"),
                                                           "speed": .string("75%")])], echo: "Stand By Me"),
                    row("a2", "agent", Self.learned)]
        let more: [(ThreadRow, String)] = [
            (tap("speed", "choose", ["choice": .string("Half")], echo: "Half"), Self.speed),
            (tap("bar", "choose", ["choice": .string("Bar 3: F#m")], echo: "Bar 3: F#m"), Self.bar),
            (tap("click", "metronome", ["bpm": .number(59), "seconds": .number(12)], echo: "Practiced 12 s at 59 BPM"), Self.clicked),
        ]
        for (i, m) in more.prefix(after).enumerated() { rows += [m.0, row("a\(i + 3)", "agent", m.1)] }
        let store = ChatStore()
        store.load(rows)
        return store
    }

    private func page(_ store: ChatStore, _ n: Int) -> [YLComponent] {
        store.onPage(n).flatMap { $0.yl?.onPage(n, style: [:]) ?? [] }
    }

    private func one(_ store: ChatStore, _ n: Int, _ id: String) throws -> YLComponent {
        try XCTUnwrap(page(store, n).first { $0.ylID == id }, "no \(id) on page \(n)")
    }

    /// The chord buttons a `chords` component draws.
    private func buttons(_ c: YLComponent) -> [String] {
        Theory.progression(key: Theory.Key(c.string("key")), prog: c.strings("prog") ?? [], chords: c.strings("chords") ?? []).map(\.name)
    }

    func testABeatIsKeptPerAgentAndLooperAndComesBackOnARelaunch() {
        let base = LoopDrafts.base(p: ["x...x...", "..x...x."], rows: ["kick", "snare"], steps: 8, bpm: 92, swing: 0)
        let beat = LoopDrafts.Draft(base: base, p: ["x...x...", "x.x...x."], bpm: 94, swing: 25)
        let drafts = LoopDrafts(defaults: defaults)
        drafts.set("gouda-1", "looper", beat)
        XCTAssertEqual(drafts.draft("gouda-1", "looper", base: base), beat)
        // Another agent's looper of the same name, and another looper, start as the agent drew them.
        XCTAssertNil(drafts.draft("arnold-1", "looper", base: base))
        XCTAssertNil(drafts.draft("gouda-1", "jam", base: base))
        // A relaunch: nothing in memory, only UserDefaults.
        XCTAssertEqual(LoopDrafts(defaults: defaults).draft("gouda-1", "looper", base: base), beat)
        LoopDrafts(defaults: defaults).clear("gouda-1", "looper")
        XCTAssertNil(LoopDrafts(defaults: defaults).draft("gouda-1", "looper", base: base))
        XCTAssertNil(defaults.object(forKey: LoopDrafts.key("gouda-1", "looper")), "a cleared beat leaves nothing behind")
    }

    func testAnotherLoopFromTheAgentDropsTheBeat() {
        let lazy = LoopDrafts.base(p: ["x...x..."], rows: ["kick"], steps: 8, bpm: 92, swing: 0)
        let night = LoopDrafts.base(p: ["x.x.x.x."], rows: ["kick"], steps: 8, bpm: 92, swing: 0)
        let drafts = LoopDrafts(defaults: defaults)
        drafts.set("g", "looper", .init(base: lazy, p: ["xxxxxxxx"], bpm: 92, swing: 0))
        // Reading on another loop never forgets (the chat's old copy is still Lazy Sunday).
        XCTAssertNil(drafts.draft("g", "looper", base: night))
        XCTAssertNotNil(drafts.draft("g", "looper", base: lazy))
        // Drawn again as the same loop: kept. As another (a session opened): gone for good.
        drafts.prune("g", "looper", base: lazy)
        XCTAssertNotNil(LoopDrafts(defaults: defaults).draft("g", "looper", base: lazy))
        drafts.prune("g", "looper", base: night)
        XCTAssertNil(LoopDrafts(defaults: defaults).draft("g", "looper", base: lazy))
    }

    func testOnlyNamedLoopersWithAnAgentAreKept() {
        XCTAssertTrue(LoopDrafts.keeps("gouda-1", "looper"))
        XCTAssertFalse(LoopDrafts.keeps("gouda-1", "n2"), "n2 is only its place in one reply")
        XCTAssertFalse(LoopDrafts.keeps("", "looper"))
        let drafts = LoopDrafts(defaults: defaults)
        drafts.set("gouda-1", "n2", .init(base: "b", p: ["x"], bpm: 90, swing: 0))
        XCTAssertNil(drafts.draft("gouda-1", "n2", base: "b"))
    }

    func testEveryReplyParsesCleanAgainstHisPages() {
        let known = Dictionary(YuiLines.parse(fence(AgentStore.demoHome["gouda"]!)).compactMap { n -> (String, String)? in
            guard n.op == .add, let id = n.id, let p = n.preset else { return nil }
            return (id, p)
        }, uniquingKeysWith: { $1 })
        for (name, reply) in [("learn", Self.learn), ("learned", Self.learned), ("speed", Self.speed), ("bar", Self.bar),
                              ("clicked", Self.clicked), ("take", Self.take), ("saved", Self.saved)] {
            // Once a song is on Chords, its speed and bar pickers are on the page too.
            let ids = ["learn", "learned", "take", "saved"].contains(name) ? known : known.merging(["speed": "choose", "bar": "choose"]) { $1 }
            let bad = YuiLines.parse(fence(reply), known: ids).filter { $0.op == .error }
            XCTAssertEqual(bad.map { $0.message ?? "" }, [], name)
        }
    }

    func testLearnASongIsOnePlanWithOneSend() throws {
        let yl = YLScreen(fence(Self.learn))
        let plan = try XCTUnwrap(yl.components.first { $0.preset == "plan" })
        XCTAssertEqual(plan.string("submit"), "Let's play")
        let asks = yl.components.filter { $0.inGroup == plan.ylID && $0.preset != "page" }.map(\.ylID)
        XCTAssertEqual(asks, ["song", "own", "key", "speed"], "the questions come after the page, in the plan")
        XCTAssertEqual(yl.components.first { $0.ylID == "song" }?.strings("options")?.first, "Stand By Me")
    }

    func testASongLandsOnChordsReadyToPlay() throws {
        let store = learned()
        XCTAssertEqual(store.screens, [1, 2, 3, 4, 5, 6])
        let chords = try one(store, 3, "chords")
        XCTAssertEqual(buttons(chords), ["A", "F#m", "D", "E"], "the home's C I-V-vi-IV is still on the buttons")
        XCTAssertEqual(chords.string("title"), "Stand By Me")
        XCTAssertEqual(try one(store, 3, "click").props["bpm"]?.number, 89)
        XCTAssertEqual(page(store, 3).map(\.ylID), ["lesson", "chords", "click", "speed", "bar"])
        // Keys follows the song's key.
        XCTAssertEqual(try one(store, 4, "keys").string("key"), "A")
        XCTAssertEqual(try one(store, 4, "keys").string("title"), "Keys, in A")
        XCTAssertEqual(try one(store, 5, "next-up").string("title"), "Next: Stand By Me at 89")
        XCTAssertEqual(store.awaitingYou.map(\.ask.ylID), [], "his pages' pickers read as waiting on you")
        XCTAssertEqual(store.page, 1, "loading the thread moved the person")
    }

    func testSpeedAndBarPatchInPlace() throws {
        let slowed = learned(1)
        XCTAssertEqual(try one(slowed, 3, "click").props["bpm"]?.number, 59)
        XCTAssertEqual(buttons(try one(slowed, 3, "chords")), ["A", "F#m", "D", "E"])
        XCTAssertEqual(page(slowed, 3).count, 5, "a patch added to the page")
        let looped = learned(2)
        XCTAssertEqual(buttons(try one(looped, 3, "chords")), ["F#m", "D"], "the looped bar is not on the buttons")
        XCTAssertEqual(try one(looped, 3, "chords").string("title"), "Stand By Me, bar 3")
        XCTAssertEqual(try one(looped, 3, "lesson").string("sub"), "Looping bar 3")
        XCTAssertEqual(try one(looped, 3, "click").props["bpm"]?.number, 59)
    }

    func testChordNamesPatchedOverAProgressionReplaceIt() {
        // The home draws numerals; a later reply that names chords wins over them.
        var yl = YLScreen(#"chords@chords C I-V-vi-IV "Chords" +inline"#)
        XCTAssertEqual(buttons(yl.components[0]), ["C", "G", "Am", "F"])
        for n in YuiLines.parse(#"~chords "G"|"D"|"Em"|"C" "Stand By Me" +inline"#, known: ["chords": "chords"]) { yl.apply(n) }
        XCTAssertEqual(buttons(yl.components[0]), ["G", "D", "Em", "C"])
    }

    func testTheClickLogsPracticeOnHisPracticePage() throws {
        let store = learned(3)
        XCTAssertEqual(try one(store, 5, "streak").string("value"), "1 day")
        XCTAssertEqual(try one(store, 5, "week-min").string("value"), "1 min")
        XCTAssertEqual(try one(store, 5, "practice-chart").strings("y")?.first, "1")
        XCTAssertEqual(try one(store, 5, "recent").strings("items"), ["09/28 1 min, Stand By Me"])
    }

    func testTheLooperSavesAndComesBackAsTheRuntimeDrawsIt() throws {
        let beat: [String: YLValue] = ["bpm": .number(92), "swing": .number(0), "steps": .number(8),
                                       "p": .array(["x...x...", "..x...x.", "", "x.x.x.x."].map(YLValue.string))]
        let store = ChatStore()
        store.load([home, tap("looper", "loop", beat, echo: "Sent my beat, 92 BPM"), row("a1", "agent", Self.take),
                    tap("keep", "plan", ["plan": .object(["name": .string("Night drive"), "then": .string("Keep it on my Looper")])],
                        echo: "Night drive"),
                    row("a2", "agent", Self.saved)])
        let looper = try one(store, 2, "looper")
        XCTAssertEqual(looper.string("title"), "Night drive")
        XCTAssertEqual(looper.strings("p"), ["x...x...", "..x...x.", "........", "x.x.x.x."])
        XCTAssertEqual(try one(store, 2, "sessions").strings("options")?.first, "Night drive")
        XCTAssertEqual(page(store, 2).count, 2, "the save added to the Looper page")
    }

    func testAClickStillGoingStopsBeforeTheThreadSwitchesAgents() {
        let host = MusicHost.shared
        var stopped = 0
        host.metroStop = { stopped += 1 }
        host.leavingAgent()
        XCTAssertEqual(stopped, 1, "the click was not stopped before the switch")
        host.leavingAgent()
        XCTAssertEqual(stopped, 1, "a stopped click stopped twice")
        XCTAssertNil(host.metroStop)
    }

    private func fence(_ reply: String) -> String {
        guard let r = reply.range(of: "```yui\n") else { return reply }
        return String(reply[r.upperBound...]).components(separatedBy: "\n```")[0]
    }
}
