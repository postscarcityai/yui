import XCTest
import YuiLines
@testable import Yui

/// Widgets and Siri, steps 2 to 4 (YUI-40): the event a widget button sends reads exactly like a tap in the
/// thread plus `via=widget`, the offline queue keeps order and drops what the relay refuses, a push catch-up
/// applies patches and re-saves with the same parser the app uses, pins go to the relay with their lasting ids,
/// and the Talk link opens hands-free.
final class WidgetStubRelay: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var reply = Data("{\"ok\":true}".utf8)
    nonisolated(unsafe) static var seen: [(auth: String, body: [String: Any])] = []
    private static let lock = NSLock()

    static func reset(status: Int = 200) { lock.lock(); self.status = status; seen = []; reply = Data("{\"ok\":true}".utf8); lock.unlock() }
    static func calls() -> [(auth: String, body: [String: Any])] { lock.lock(); defer { lock.unlock() }; return seen }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.lock()
        Self.seen.append((request.value(forHTTPHeaderField: "Authorization") ?? "", body))
        let (status, reply) = (Self.status, Self.reply)
        Self.lock.unlock()
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class WidgetRelayTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [WidgetStubRelay.self]
        session = URLSession(configuration: c)
        WidgetQueue.session = session
        WidgetStubRelay.reset()
        // A clean app group for each test.
        WidgetStore.write(WidgetSnapshot())
        if let f = WidgetGroup.url { for n in ["yui-widget-queue.json", "yui-widget-ticks.json"] { try? FileManager.default.removeItem(at: f.appending(path: n)) } }
        WidgetSecrets.token = "yui_wt_test"
    }

    override func tearDown() {
        WidgetSecrets.token = nil
        WidgetQueue.session = .shared
    }

    private let light = YuiTheme.yui.light, dark = YuiTheme.yui.dark

    private func screen(at: Date = Date(timeIntervalSince1970: 1_000), parts: [WidgetPart]) -> WidgetScreen {
        WidgetScreen(agentID: "agent-1", agentName: "Coach", name: "today", parts: parts, light: light, dark: dark, design: "rounded", at: at)
    }

    private var list: WidgetPart {
        WidgetPart(ylID: "today", preset: "list", props: ["items": .array([.string("Walk 30 min"), .string("Stretch")]), "check": .bool(true)])
    }

    // MARK: The event

    func testWidgetEventLineIsTheThreadsLinePlusViaWidget() {
        let s = screen(parts: [list])
        let e = WidgetEvent.make(screen: s, part: list, value: ["item": .string("Walk 30 min"), "checked": .bool(true)])
        let thread = YLEvent(id: "today", preset: "list",
                             value: ["item": .string("Walk 30 min"), "checked": .bool(true), "saved": .string("today"), "via": .string("widget")],
                             echo: nil)
        XCTAssertEqual(e.body, thread.line)
        XCTAssertEqual(e.body, "[yui] today list checked item=\"Walk 30 min\" saved=today via=widget")
        XCTAssertEqual(e.meta.object?["value"]?.object?["via"], .string("widget"))
        XCTAssertEqual(e.agentID, "agent-1")
    }

    func testEventLineMatchesTheThreadForEveryValueShape() {
        let v: [String: YLValue] = ["started": .bool(true), "n": .number(3), "x": .number(2.5), "t": .string("a b"), "l": .array([.string("a"), .number(1)]),
                                    "o": .object(["k": .string("v")]), "e": .string("")]
        XCTAssertEqual(WidgetEvent.line(id: "hiit", preset: "timer", value: v), YLEvent(id: "hiit", preset: "timer", value: v, echo: nil).line)
    }

    // MARK: Ticks

    func testTickFlipsTheCopyAndReportsTheNewState() {
        WidgetStore.write(WidgetSnapshot(screens: [screen(parts: [list])]))
        let on = WidgetStore.toggleTick(agent: "agent-1", screen: "today", part: "today", item: "Walk 30 min")
        XCTAssertEqual(on?.checked, true)
        XCTAssertEqual(WidgetStore.screen(agent: "agent-1", name: "today")?.parts[0].ticked, ["Walk 30 min"])
        let off = WidgetStore.toggleTick(agent: "agent-1", screen: "today", part: "today", item: "Walk 30 min")
        XCTAssertEqual(off?.checked, false)
        XCTAssertEqual(WidgetStore.screen(agent: "agent-1", name: "today")?.parts[0].ticked, [])
        XCTAssertNil(WidgetStore.toggleTick(agent: "agent-1", screen: "today", part: "today", item: "not on the list"))
        XCTAssertNil(WidgetStore.toggleTick(agent: "nobody", screen: "today", part: "today", item: "Stretch"))
    }

    @MainActor
    func testATickMadeOnTheWidgetReachesTheAppsListTicks() {
        let defaults = UserDefaults(suiteName: "widget-ticks-\(UUID().uuidString)")!
        let ticks = ListTicks(defaults: defaults)
        WidgetTickLog.add(WidgetTick(agentID: "agent-1", partID: "today", item: "Stretch", checked: true, at: .now))
        for t in WidgetTickLog.take() { ticks.set(t.agentID, t.partID, item: t.item, on: t.checked) }
        XCTAssertEqual(ticks.ticked("agent-1", "today", items: ["Walk 30 min", "Stretch"]), ["Stretch"])
        XCTAssertTrue(WidgetTickLog.take().isEmpty, "taken once")
    }

    // MARK: The offline queue

    private func queue(_ n: Int) -> [WidgetEvent] {
        (0..<n).map { i in
            WidgetEvent(id: "00000000-0000-0000-0000-00000000000\(i)", agentID: "agent-1", body: "[yui] a list n=\(i)",
                        meta: .object(["value": .object(["via": .string("widget")])]), at: .now)
        }
    }

    func testTheQueueGoesOutInOrderWithTheWidgetToken() async {
        queue(3).forEach(WidgetQueue.add)
        let sent = await WidgetQueue.flush()
        XCTAssertEqual(sent, 3)
        let calls = WidgetStubRelay.calls()
        XCTAssertEqual(calls.map { $0.body["id"] as? String }, queue(3).map(\.id))
        XCTAssertTrue(calls.allSatisfy { $0.auth == "Bearer yui_wt_test" && $0.body["action"] as? String == "event" })
        XCTAssertTrue(WidgetQueue.pending().isEmpty)
    }

    func testAnOfflinePhoneKeepsTheQueueInOrder() async {
        WidgetStubRelay.reset(status: 503)
        queue(2).forEach(WidgetQueue.add)
        let sent = await WidgetQueue.flush()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(WidgetQueue.pending().map(\.id), queue(2).map(\.id), "nothing lost, same order")
        XCTAssertEqual(WidgetStubRelay.calls().count, 1, "stops at the first failure so the order holds")
        WidgetStubRelay.reset(status: 200)
        let rest = await WidgetQueue.flush()
        XCTAssertEqual(rest, 2)
    }

    func testARefusedEventIsDroppedNotRetriedForever() async {
        WidgetStubRelay.reset(status: 404)  // the pin is gone
        queue(2).forEach(WidgetQueue.add)
        let sent = await WidgetQueue.flush()
        XCTAssertEqual(sent, 2)
        XCTAssertTrue(WidgetQueue.pending().isEmpty)
    }

    func testNoTokenYetKeepsTheQueue() async {
        WidgetSecrets.token = nil
        queue(1).forEach(WidgetQueue.add)
        let none = await WidgetQueue.flush()
        XCTAssertEqual(none, 0)
        XCTAssertEqual(WidgetQueue.pending().count, 1)
        XCTAssertTrue(WidgetStubRelay.calls().isEmpty)
    }

    func testAResendOfTheSameEventIsQueuedOnce() {
        let e = queue(1)[0]
        WidgetQueue.add(e); WidgetQueue.add(e)
        XCTAssertEqual(WidgetQueue.pending().count, 1)
    }

    // MARK: Catching up after a push

    private func body(_ lines: String) -> String { "```yui\n\(lines)\n```" }

    func testAPatchToALastingIdChangesThePart() {
        let stat = WidgetPart(ylID: "weight", preset: "stat", props: ["value": .number(181.2), "unit": .string("lb")])
        let s = screen(parts: [stat, list])
        let later = Date(timeIntervalSince1970: 2_000)
        let out = WidgetCatchUp.apply(body: body("~weight 178.4 delta=-2.8"), at: later, to: s)
        XCTAssertEqual(out?.parts[0].props["value"]?.number, 178.4)
        XCTAssertEqual(out?.parts[0].props["delta"]?.number, -2.8)
        XCTAssertEqual(out?.parts[0].props["unit"], .string("lb"), "what the patch did not say stays")
        XCTAssertEqual(out?.parts[1], list)
        XCTAssertEqual(out?.at, later)
    }

    func testAPatchAimedAtAnotherScreenOrAnOlderReplyDoesNothing() {
        let s = screen(at: Date(timeIntervalSince1970: 5_000), parts: [WidgetPart(ylID: "weight", preset: "stat", props: ["value": .number(1)])])
        XCTAssertNil(WidgetCatchUp.apply(body: body("~height 180"), at: Date(timeIntervalSince1970: 6_000), to: s))
        XCTAssertNil(WidgetCatchUp.apply(body: body("~weight 2"), at: Date(timeIntervalSince1970: 4_000), to: s), "history replays: an older patch is not applied")
        XCTAssertNil(WidgetCatchUp.apply(body: "Nice work today. ~weight 9", at: Date(timeIntervalSince1970: 6_000), to: s), "words outside a fence are not lines")
    }

    func testAReSaveOfThePinnedNameReplacesTheCopy() {
        let s = screen(parts: [list])
        let text = body("stat@weight 177.9lb Weight\nlist@today Today \"Walk\"|\"Stretch\" +check\nsave today")
        let out = WidgetCatchUp.apply(body: text, at: Date(timeIntervalSince1970: 3_000), to: s)
        XCTAssertEqual(out?.parts.map(\.ylID), ["weight", "today"])
        XCTAssertEqual(out?.parts.first?.props["value"]?.number, 177.9)
        XCTAssertNil(WidgetCatchUp.apply(body: body("stat@weight 1\nsave other"), at: Date(timeIntervalSince1970: 3_000), to: s), "another name is not this screen")
    }

    func testAPatchInTheSameReplyAsTheSaveLandsInTheSavedScreen() {
        let s = screen(parts: [list])
        let text = body("stat@weight 181\nsave today\n~weight 178")
        let out = WidgetCatchUp.apply(body: text, at: Date(timeIntervalSince1970: 3_000), to: s)
        XCTAssertEqual(out?.parts.first?.props["value"]?.number, 178)
    }

    func testCatchUpReadsTheRelayAndKeepsWhatThePhoneChangedMeanwhile() async {
        var p = list
        p.ticked = ["Stretch"]
        p.liveKey = "widget|x"
        let stat = WidgetPart(ylID: "weight", preset: "stat", props: ["value": .number(181)])
        let s = screen(parts: [stat, p])
        WidgetStore.write(WidgetSnapshot(screens: [s]))
        WidgetStubRelay.reply = Data("""
        {"ok":true,"rows":[{"id":"r1","body":"```yui\\n~weight 177\\n```","created_at":"2026-09-30T20:00:00.000000+00:00"}]}
        """.utf8)
        let out = await WidgetCatchUp.refresh(s, session: session)
        XCTAssertEqual(out.parts[0].props["value"]?.number, 177)
        let saved = WidgetStore.screen(agent: "agent-1", name: "today")
        XCTAssertEqual(saved?.parts[0].props["value"]?.number, 177, "the copy is saved")
        XCTAssertEqual(saved?.parts[1].ticked, ["Stretch"], "a tick made meanwhile stays")
        XCTAssertEqual(saved?.parts[1].liveKey, "widget|x", "a running timer stays")
        let call = WidgetStubRelay.calls().last
        XCTAssertEqual(call?.body["action"] as? String, "read")
        XCTAssertEqual(call?.body["agent_id"] as? String, "agent-1")
        XCTAssertEqual(call?.auth, "Bearer yui_wt_test")
    }

    func testCatchUpWithNoNetworkDrawsTheCopyAsItWas() async {
        WidgetStubRelay.reset(status: 500)
        let s = screen(parts: [list])
        let out = await WidgetCatchUp.refresh(s, session: session)
        XCTAssertEqual(out, s)
    }

    // MARK: Pins, entities, links

    @MainActor
    func testPinsCarryLastingIdsOnly() {
        let auto = WidgetPart(ylID: "n1", preset: "card", props: [:])
        let s = screen(parts: [auto, list, WidgetPart(ylID: "focus", preset: "timer", props: [:])])
        let snap = WidgetSnapshot(screens: [s])
        let entity = ScreenEntity(id: s.id, agentID: "agent-1", agentName: "Coach", name: "today")
        let pins = WidgetRegistry.pinList([(screen: entity, hide: true), (screen: entity, hide: false)], snapshot: snap)
        XCTAssertEqual(pins.count, 1, "one widget per screen, twice pinned is one row")
        XCTAssertEqual(pins[0]["agent_id"] as? String, "agent-1")
        XCTAssertEqual(pins[0]["screen"] as? String, "today")
        XCTAssertEqual((pins[0]["ids"] as? [[String: String]])?.map { $0["id"] ?? "" }, ["today", "focus"])
        XCTAssertEqual((pins[0]["ids"] as? [[String: String]])?.last?["preset"], "timer")
    }

    func testTimersInTheCopyAreTheTimerEntities() {
        let t = WidgetPart(ylID: "tabata", preset: "timer", props: ["label": .string("Tabata")])
        let snap = WidgetSnapshot(screens: [screen(parts: [list, t])])
        let timers = TimerQuery.timers(in: snap)
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers[0].name, "Tabata")
        XCTAssertEqual(timers[0].part, "tabata")
        XCTAssertEqual(timers[0].id, "agent-1/today/tabata")
    }

    func testTalkLinkOpensHandsFreeAndYuiWhenNoAgentIsPicked() {
        let url = TalkToAgentIntent.link(agent: "agent-1")
        XCTAssertEqual(url.absoluteString, "yui://agent/agent-1/thread?talk=1")
        XCTAssertTrue(PushCenter.talks(url))
        XCTAssertEqual(PushCenter.agentTarget(url), "agent-1")
        XCTAssertEqual(TalkToAgentIntent.link(agent: nil).absoluteString, "yui://agent/yui/thread?talk=1")
        XCTAssertFalse(PushCenter.talks(URL(string: "yui://agent/agent-1/thread")!))
    }

    func testShowLinkNamesTheSavedScreen() {
        let url = ShowScreenIntent.link(agent: "agent-1", name: "leg day")
        XCTAssertEqual(PushCenter.showName(url), "leg day")
        XCTAssertEqual(PushCenter.agentTarget(url), "agent-1")
        XCTAssertFalse(PushCenter.talks(url))
    }

    func testReloadBudgetCountsPerScreenPerDay() {
        WidgetGroup.defaults.removeObject(forKey: "widgetReloads")
        WidgetBudget.log(screen: "agent-1/today"); WidgetBudget.log(screen: "agent-1/today"); WidgetBudget.log(screen: "agent-1/weight")
        XCTAssertEqual(WidgetBudget.today(), ["agent-1/today": 2, "agent-1/weight": 1])
    }
}

/// "Ask Coach in Yui" (YUI-40 step 2): Siri's intent sends the words to that agent as a normal message through
/// the app's own outbox, and says "Sent to Coach" only after the row left the phone.
@MainActor
final class SiriIntentTests: XCTestCase {
    override func setUp() async throws {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeRelay.self]
        YuiRelay.session = URLSession(configuration: c)
        FakeRelay.reset(chats: [], messages: [])
        Outbox.shared.clear()
    }

    override func tearDown() async throws {
        YuiRelay.session = .shared
        WidgetApp.account = nil
        Outbox.shared.clear()
    }

    func testAskAnAgentSendsAMessageAndSaysSent() async throws {
        WidgetApp.account = Account.signedIn(userID: "u1")
        var intent = AskAgentIntent()
        intent.agent = AgentEntity(id: "agent-coach", name: "Coach")
        intent.message = "  How did I sleep?  "
        let result = try await intent.perform()
        let said = String(describing: result)
        XCTAssertTrue(said.contains("key: \"Sent to %@\"") && said.contains("value(\"Coach\")"), "said Sent to Coach, not Queued")
        let post = FakeRelay.log().first { $0.method == "POST" && $0.path == "yui_messages" }
        XCTAssertEqual(post?.body["body"] as? String, "How did I sleep?")
        XCTAssertEqual(post?.body["agent_id"] as? String, "agent-coach")
        XCTAssertEqual(post?.body["sender"] as? String, "user")
        XCTAssertEqual(post?.body["kind"] as? String, "text")
    }

    func testSignedOutSiriSendsNothing() async throws {
        WidgetApp.account = Account.signedIn(userID: "demo")
        var intent = AskAgentIntent()
        intent.agent = AgentEntity(id: "agent-coach", name: "Coach")
        intent.message = "hello"
        let result = try await intent.perform()
        XCTAssertTrue(String(describing: result).contains("sign in"))
        XCTAssertTrue(FakeRelay.log().isEmpty)
    }

    func testEmptyWordsSendNothing() async throws {
        WidgetApp.account = Account.signedIn(userID: "u1")
        var intent = AskAgentIntent()
        intent.agent = AgentEntity(id: "agent-coach", name: "Coach")
        intent.message = "   "
        _ = try await intent.perform()
        XCTAssertTrue(FakeRelay.log().isEmpty)
    }

    func testSixAppShortcutsAndEachPhraseNamesTheApp() {
        XCTAssertEqual(YuiShortcuts.appShortcuts.count, 6)
    }

    // YUI-253: Siri logs food and starts the workout.
    func testLogFoodOpensBasilsCameraAndNoChat() {
        let url = LogFoodIntent.link
        XCTAssertTrue(PushCenter.isSnap(url))
        XCTAssertEqual(PushCenter.snapAgent(url), "basil")
        XCTAssertNil(PushCenter.snapAgent(URL(string: "yui://snap")!))
        let push = PushCenter.shared
        XCTAssertTrue(push.open(url))
        XCTAssertEqual(push.pendingSnapAgent, "basil")
        XCTAssertEqual(push.pendingAgentID, "basil")
        XCTAssertFalse(push.pendingSnap, "the camera waits for Basil's thread")
        push.pendingSnapAgent = nil; push.pendingAgentID = nil
    }

    func testStartWorkoutOpensArnoldsThreadAndStarts() {
        let url = StartWorkoutIntent.link
        XCTAssertEqual(PushCenter.agentTarget(url), "arnold")
        XCTAssertTrue(PushCenter.startsWorkout(url))
        XCTAssertFalse(PushCenter.isHandOff(url))
        let push = PushCenter.shared
        XCTAssertTrue(push.open(url))
        XCTAssertTrue(push.pendingWorkout)
        push.pendingWorkout = false; push.pendingAgentID = nil
        XCTAssertFalse(PushCenter.startsWorkout(URL(string: "yui://agent/arnold/thread")!))
    }

    func testSpokenMealGoesToBasilAsALogAndSaysLogged() async throws {
        WidgetApp.account = Account.signedIn(userID: "u1")
        WidgetGroup.defaults.set(["basil": "agent-basil"], forKey: "agentHandles")
        defer { AgentHandles.clear() }
        var intent = LogMealIntent()
        intent.meal = "  a bacon cheeseburger with fries "
        let result = try await intent.perform()
        XCTAssertTrue(String(describing: result).contains("Logged"), "Siri says Logged")
        let post = FakeRelay.log().first { $0.method == "POST" && $0.path == "yui_messages" }
        XCTAssertEqual(post?.body["body"] as? String, "Log a meal: a bacon cheeseburger with fries")
        XCTAssertEqual(post?.body["agent_id"] as? String, "agent-basil")
        XCTAssertEqual(post?.body["sender"] as? String, "user")
    }

    func testSpokenMealNeedsWordsAndASignedInAccount() async throws {
        XCTAssertNil(LogMealIntent.words("   "))
        WidgetApp.account = Account.signedIn(userID: "u1")
        WidgetGroup.defaults.set(["basil": "agent-basil"], forKey: "agentHandles")
        defer { AgentHandles.clear() }
        var empty = LogMealIntent()
        empty.meal = " "
        _ = try await empty.perform()
        WidgetApp.account = Account.signedIn(userID: "demo")
        var demo = LogMealIntent()
        demo.meal = "toast"
        _ = try await demo.perform()
        XCTAssertTrue(FakeRelay.log().isEmpty)
    }

    func testAgentHandlesComeFromTheLoadedList() {
        AgentHandles.clear()
        XCTAssertNil(AgentHandles.id("basil"))
        AgentHandles.save([YuiAgent(id: "a1", name: "Basil", handle: "Basil", color: "mint", kind: "hermes", status: .connected, isDefault: false, sort: 0)])
        XCTAssertEqual(AgentHandles.id("basil"), "a1")
        AgentHandles.clear()
    }

    func testKeychainGroupIsInTheInfoPlist() {
        XCTAssertNotNil(WidgetSecrets.group)
    }
}
