import XCTest
import YuiLines
@testable import Yui

/// Group threads (YUI-94): rows in, things to draw out; who a message goes to; the errors in words.
/// Spec: yuigui/spec/GROUPS.md, section 7.
@MainActor
final class GroupRowsTests: XCTestCase {
    static let at = "2026-10-01T14:00:00.000000+00:00"
    let coach = "c0000000-0000-4000-8000-000000000001"
    let sage = "c0000000-0000-4000-8000-000000000002"
    let quill = "c0000000-0000-4000-8000-000000000003"

    func row(_ id: String, _ sender: String, _ body: String, agent: String? = nil, kind: String = "text",
             group: [String: YLValue]? = nil, extra: [String: YLValue] = [:], handled: String? = nil,
             delivered: String? = nil, at: String = GroupRowsTests.at) -> ThreadRow {
        var meta = extra
        if let group { meta["group"] = .object(group) }
        return ThreadRow(id: id, sender: sender, body: body, kind: kind, meta: .object(meta), createdAt: at,
                         deliveredAt: delivered, handledAt: handled, agentID: agent)
    }

    func testPersonRowDrawsTheWordsNotTheQuote() {
        let r = row("u1", "user", "[yui] group \"Race week\" hop=0 from=person\n> Person: hi\n@Sage what should I eat?",
                    agent: sage, group: ["words": .string("@Sage what should I eat?"), "to": .array([.string(sage)])])
        guard case .you(_, let text, let to, _)? = GroupRows.item(r) else { return XCTFail("not a person bubble") }
        XCTAssertEqual(text, "@Sage what should I eat?")
        XCTAssertEqual(to, [sage])
    }

    func testPersonRowWithoutWordsStripsTheHeaderAndQuote() {
        let r = row("u1", "user", "[yui] group \"G\" hop=0 from=person\nRace week, just before:\n> Person: hi\nplan Saturday", agent: coach)
        guard case .you(_, let text, _, _)? = GroupRows.item(r) else { return XCTFail() }
        XCTAssertTrue(text.hasSuffix("plan Saturday"))
        XCTAssertFalse(text.contains("[yui]"))
        XCTAssertFalse(text.contains("> Person"))
    }

    func testCopiesAndControlRowsAreHidden() {
        XCTAssertNil(GroupRows.item(row("c1", "user", "x", agent: sage, group: ["copy_of": .string("u1")])))
        XCTAssertNil(GroupRows.item(row("c2", "user", "[yui] group stop", agent: coach, group: ["control": .string("stop")])))
        XCTAssertNil(GroupRows.item(row("c3", "user", "[yui] group continue guard=g", agent: coach,
                                        group: ["control": .string("continue"), "guard": .string("g")])))
        XCTAssertNil(GroupRows.item(row("c4", "agent", "{}", agent: coach, kind: "control")))
    }

    func testAnAgentReplyIsABubbleForThatAgent() {
        guard case .agent(_, let agent, let text, _)? = GroupRows.item(row("a1", "agent", "Five days.", agent: coach, group: ["hop": .number(0)])) else {
            return XCTFail()
        }
        XCTAssertEqual(agent, coach)
        XCTAssertEqual(text, "Five days.")
    }

    func testHandoffRowNamesBothAgentsAndOneLineOfTheAsk() {
        let body = "[yui] group \"Race week\" hop=1 from=coach\nRace week, just before:\n> Coach: Five days.\n@Sage can you fit a wind-down before bed each night?"
        let r = row("h1", "user", body, agent: sage,
                    group: ["from": .string(coach), "from_name": .string("Coach"), "msg": .string("a1"), "hop": .number(1)])
        guard case .handoff(_, let from, let to, let ask, let msg, let cancelled)? = GroupRows.item(r) else { return XCTFail() }
        XCTAssertEqual(from, coach)
        XCTAssertEqual(to, sage)
        XCTAssertEqual(ask, "can you fit a wind-down before bed each night?")
        XCTAssertEqual(msg, "a1")
        XCTAssertFalse(cancelled)
    }

    func testCancelledHandoffSaysSo() {
        let r = row("h1", "user", "[yui] group x\n@Sage hi", agent: sage,
                    group: ["from": .string(coach), "cancelled": .bool(true)])
        guard case .handoff(_, _, _, _, _, let cancelled)? = GroupRows.item(r) else { return XCTFail() }
        XCTAssertTrue(cancelled)
    }

    func testGuardRowCarriesItsStateAndTarget() {
        let g: [String: YLValue] = ["guard": .object(["to": .string(quill), "to_name": .string("Quill"), "from": .string(coach),
                                                       "msg": .string("a2"), "hop": .number(4), "reason": .string("hops"),
                                                       "state": .string("held")])]
        guard case .guardAsk(let id, let asker, let to, let toName, let text, let state)? =
            GroupRows.item(row("g1", "agent", "Coach wants to ask Quill: \"cards\"\nThat's 3 handoffs since you last said something.",
                               agent: coach, group: g)) else { return XCTFail() }
        XCTAssertEqual(id, "g1"); XCTAssertEqual(asker, coach); XCTAssertEqual(to, quill); XCTAssertEqual(toName, "Quill")
        XCTAssertEqual(state, .held)
        XCTAssertTrue(text.contains("3 handoffs"))
        for (raw, want) in [("continued", GroupItem.GuardState.continued), ("stopped", .stopped), ("gone", .gone)] {
            var meta = g
            meta["guard"] = .object(["to": .string(quill), "state": .string(raw)])
            guard case .guardAsk(_, _, _, _, _, let s)? = GroupRows.item(row("g2", "agent", "x", agent: coach, group: meta)) else { return XCTFail() }
            XCTAssertEqual(s, want)
        }
    }

    func testStatusLineIsAboutTheAgentItNames() {
        let r = row("s1", "agent", "Sage is asleep. It gets this when its computer wakes.", agent: sage,
                    group: ["status": .string("asleep"), "about": .string(sage)])
        guard case .status(_, let about, let text)? = GroupRows.item(r) else { return XCTFail() }
        XCTAssertEqual(about, sage)
        XCTAssertTrue(text.hasPrefix("Sage is asleep"))
    }

    func testATapOnAScreenShowsWhatWasPickedOrNothing() {
        let line = "[yui] pick-day choose answer=Legs"
        let shown = row("t1", "user", "[yui] group x\n" + line, agent: sage,
                        group: ["to": .array([.string(sage)]), "words": .string(line)], extra: ["echo": .string("Legs")])
        guard case .you(_, let text, _, _)? = GroupRows.item(shown) else { return XCTFail() }
        XCTAssertEqual(text, "Legs")
        XCTAssertNil(GroupRows.item(row("t2", "user", "[yui] group x\n" + line, agent: sage,
                                        group: ["to": .array([.string(sage)]), "words": .string(line)])))
    }

    func testItemsKeepTheRowOrder() {
        let rows = [row("u1", "user", "hi", agent: coach, group: ["words": .string("hi")]),
                    row("x", "user", "copy", agent: sage, group: ["copy_of": .string("u1")]),
                    row("a1", "agent", "hello", agent: coach)]
        XCTAssertEqual(GroupRows.items(rows).map(\.id), ["u1", "a1"])
    }

    // MARK: Working rows

    func testAnAgentIsWorkingWhileItsRowIsUnhandledLeadFirst() {
        let rows = [row("u1", "user", "x", agent: sage, group: ["words": .string("x")]),
                    row("u2", "user", "x", agent: coach, group: ["copy_of": .string("u1")]),
                    row("u3", "user", "x", agent: quill, group: ["from": .string(coach)], handled: Self.at)]
        XCTAssertEqual(GroupRows.working(rows, lead: coach).map(\.agent), [coach, sage])
    }

    func testAHandledOrCancelledOrControlRowIsNotWork() {
        let rows = [row("u1", "user", "x", agent: sage, handled: Self.at),
                    row("u2", "user", "x", agent: coach, group: ["from": .string(sage), "cancelled": .bool(true)]),
                    row("u3", "user", "[yui] group stop", agent: coach, group: ["control": .string("stop")])]
        XCTAssertTrue(GroupRows.working(rows, lead: coach).isEmpty)
    }

    func testAnOfflineAgentWaitsAndDoesNotWork() {
        let rows = [row("u1", "user", "x", agent: sage, group: ["words": .string("x")]),
                    row("s1", "agent", "Sage is offline. It gets this when it's back.", agent: sage,
                        group: ["status": .string("offline"), "about": .string(sage)], at: "2026-10-01T14:00:00.000001+00:00"),
                    row("u2", "user", "y", agent: coach, group: ["words": .string("y")])]
        XCTAssertEqual(GroupRows.working(rows, lead: coach).map(\.agent), [coach])
    }

    func testWorkingCarriesTheAgentsOwnWords() {
        var r = row("u1", "user", "x", agent: sage, delivered: Self.at)
        r.doing = .object(["text": .string("Reading your notes"), "step": .number(2), "of": .number(5)])
        let w = GroupRows.working([r], lead: coach)
        XCTAssertEqual(w.first?.doing?.text, "Reading your notes")
        XCTAssertNotNil(w.first?.pickedUp)
    }

    // MARK: @ and who gets it

    let members: [YuiAgent] = [MentionFormatTests.agent("c1", "Coach", "coach"), MentionFormatTests.agent("s1", "Sage", "sage"),
                               MentionFormatTests.agent("q1", "Quill", "quill"), MentionFormatTests.agent("n1", "Nova", "nova")]

    func addressed(_ text: String) -> [String] {
        GroupRows.addressed(text, members: members, handle: \.handle, id: \.id)
    }

    func testAtNamesTheMembersInOrderOnce() {
        XCTAssertEqual(addressed("@Coach @Sage plan Saturday"), ["c1", "s1"])
        XCTAssertEqual(addressed("@sage and again @Sage"), ["s1"])
        XCTAssertEqual(addressed("how did I sleep?"), [], "no @: the lead")
        XCTAssertEqual(addressed("@Ghost hi"), [], "not a member")
        XCTAssertEqual(addressed("mail me at a@sage.com"), [], "an email is not an @")
    }

    func testThreeAddresseesAtMost() {
        XCTAssertEqual(addressed("@Coach @Sage @Quill @Nova go"), ["c1", "s1", "q1"])
    }

    func testPartialMentionAndCompletion() {
        XCTAssertEqual(GroupRows.partialMention("hey @sa"), "sa")
        XCTAssertEqual(GroupRows.partialMention("hey @"), "")
        XCTAssertNil(GroupRows.partialMention("hey @sage now"))
        XCTAssertNil(GroupRows.partialMention("no mention"))
        XCTAssertEqual(GroupRows.completing("hey @sa", with: "sage"), "hey @sage ")
    }

    func testASwipeReplyGoesToTheBubblesAuthorWhenNothingIsNamed() {
        let thread = GroupThread(info: GroupInfo(id: "g", title: "G", lead: "c1", members: ["c1", "s1"]),
                                 client: GroupClient(account: Account()))
        thread.replyTarget = "s1"
        XCTAssertEqual(thread.addressees("thanks", members: members), ["s1"])
        XCTAssertEqual(thread.addressees("@Quill thanks", members: members), ["q1"], "an @ wins over the swipe")
        thread.replyTarget = nil
        XCTAssertEqual(thread.addressees("thanks", members: members), [])
    }

    func testThreadMergesRowsOnceAndDropsASendThatLanded() {
        let thread = GroupThread(info: GroupInfo(id: "g", title: "G", lead: coach, members: [coach, sage]),
                                 client: GroupClient(account: Account()))
        thread.load([row("u1", "user", "hi", agent: coach, group: ["words": .string("hi")])])
        thread.load([row("u1", "user", "hi", agent: coach, group: ["words": .string("hi")], handled: Self.at),
                     row("a1", "agent", "hello", agent: coach, at: "2026-10-01T14:00:01.000000+00:00")])
        XCTAssertEqual(thread.items.map(\.id), ["u1", "a1"])
        XCTAssertTrue(thread.working.isEmpty, "handled_at arrived on the second read")
    }

    // MARK: Group and errors

    func testGroupDecodesItsLiveMembersAndPutsTheLeadFirst() throws {
        let json = """
        {"id":"g","title":"Race week","lead":"s1","max_hops":4,"max_turns":8,"archived_at":null,"created_at":"2026-10-01T10:00:00+00:00",
         "yui_thread_members":[{"agent_id":"c1","left_at":null},{"agent_id":"s1","left_at":null},{"agent_id":"q1","left_at":"2026-10-01T11:00:00+00:00"}]}
        """
        let g = try JSONDecoder().decode(GroupInfo.self, from: Data(json.utf8))
        XCTAssertEqual(g.members, ["c1", "s1"], "a member who left is not in it")
        XCTAssertEqual(g.maxHops, 4)
        XCTAssertEqual(g.ordered(members) { $0.id }.map(\.name), ["Sage", "Coach"])
    }

    func testEveryRefusalHasWords() {
        for m in ["update_needed", "limit_reached", "group_not_found", "group_archived", "group_agent_not_member", "group_too_many",
                  "group_uses_to", "group_guard_gone", "group_lead_not_member", "group_lead_cannot_leave"] {
            let e = GroupError(message: m)
            if case .other = e { XCTFail("\(m) not mapped") }
            XCTAssertFalse(e.spoken.isEmpty)
            XCTAssertFalse(e.spoken.contains("_"), "plain words, no codes: \(m)")
        }
        XCTAssertEqual(GroupError(message: "update_needed"), .updateNeeded)
        XCTAssertEqual(GroupError(message: "weird"), .other("weird"))
    }

    func testTitles() {
        XCTAssertEqual(GroupStore.suggestedTitle(["Coach", "Sage"]), "Coach and Sage")
        XCTAssertEqual(GroupStore.suggestedTitle(["Coach", "Sage", "Quill"]), "Coach, Sage and Quill")
        XCTAssertNil(GroupStore.validTitle("   "))
        XCTAssertEqual(GroupStore.validTitle(String(repeating: "a", count: 90))?.count, 60)
        XCTAssertEqual(GroupStore.validTitle("  Race week "), "Race week")
    }
}
