import SwiftUI
import XCTest
import YuiLines
@testable import Yui

/// @mentions (YUI-44): what the composer suggests for a draft, what a tap leaves
/// in it, which agent a message goes to, and the rows on the wire.
/// Spec: yuigui/spec/RELAY.md "Mentions".
@MainActor
final class MentionFormatTests: XCTestCase {
    static func agent(_ id: String, _ name: String, _ handle: String, presence: String = "online",
                      muted: Bool = false) -> YuiAgent {
        YuiAgent(id: id, name: name, handle: handle, color: "coral", avatar: nil, kind: "hermes", connectorID: "c",
                 connectorName: "Mac", remoteRef: handle, status: .connected, lastSeenAt: nil, isDefault: false,
                 sort: 0, pushMuted: muted, presence: presence)
    }

    static let yui = agent("a-yui", "Yui", "yui")
    static let coach = agent("a-coach", "Coach", "coach")
    static let nova = agent("a-nova", "Nova", "nova", presence: "asleep")
    static let pilot = agent("a-pilot", "Pilot", "pilot", presence: "offline")
    static let all = [yui, coach, nova, pilot]

    func testAtAloneShowsEveryOtherAgent() {
        XCTAssertEqual(Mentions.matches("@", agents: Self.all, current: "a-yui").map(\.name), ["Coach", "Nova", "Pilot"])
        XCTAssertEqual(Mentions.matches("hey @", agents: Self.all, current: "a-coach").map(\.name), ["Yui", "Nova", "Pilot"],
                       "anywhere in the draft, never the agent you're in")
    }

    func testTypingFiltersStartsFirstThenInside() {
        let odin = Self.agent("a-odin", "Odin", "odin")
        XCTAssertEqual(Mentions.matches("@o", agents: Self.all + [odin], current: "a-yui").map(\.name),
                       ["Odin", "Coach", "Nova", "Pilot"], "Odin starts with o, the rest only contain it")
        XCTAssertEqual(Mentions.matches("ask @Pi", agents: Self.all, current: "a-yui").map(\.name), ["Pilot"])
        XCTAssertEqual(Mentions.matches("@zz", agents: Self.all, current: "a-yui"), [])
    }

    func testNoPopoverOnceTheWordIsDone() {
        XCTAssertEqual(Mentions.matches("@coach ", agents: Self.all, current: "a-yui"), [], "a space: done")
        XCTAssertEqual(Mentions.matches("@Coach", agents: Self.all, current: "a-yui"), [], "the only fit, typed in full")
        XCTAssertEqual(Mentions.matches("mail me@lu", agents: Self.all, current: "a-yui"), [], "an email is not a mention")
        XCTAssertEqual(Mentions.matches("no at here", agents: Self.all, current: "a-yui"), [])
    }

    func testATapFillsTheName() {
        XCTAssertEqual(Mentions.fill("can you ask @lu", with: Self.coach), "can you ask @Coach ")
        XCTAssertEqual(Mentions.fill("@", with: Self.nova), "@Nova ")
        let s = Mentions.suggestions("@", agents: Self.all, current: "a-yui")
        XCTAssertEqual(s.map(\.detail), ["Online", "Asleep", "Offline"])
        XCTAssertEqual(s.first?.hint, "@coach")
        XCTAssertEqual(s.first?.agent?.id, "a-coach", "the row shows the agent's face")
        XCTAssertEqual(Mentions.presence(Self.agent("x", "M", "m", muted: true)), "Online, muted")
        XCTAssertEqual(Mentions.presence(Self.agent("x", "P", "p", presence: "pending")), "Not connected yet")
    }

    func testWhoTheMessageGoesTo() {
        XCTAssertEqual(Mentions.target("@Coach does this fit?", agents: Self.all, current: "a-yui")?.id, "a-coach")
        XCTAssertEqual(Mentions.target("ask @nova, then @coach", agents: Self.all, current: "a-yui")?.id, "a-nova",
                       "the first one wins")
        XCTAssertEqual(Mentions.target("hey @pilot.", agents: Self.all, current: "a-yui")?.id, "a-pilot", "by handle, before punctuation")
        XCTAssertNil(Mentions.target("@lunatic", agents: Self.all, current: "a-yui"), "a longer word is not her")
        XCTAssertNil(Mentions.target("me@coach.com", agents: Self.all, current: "a-yui"))
        XCTAssertNil(Mentions.target("@Yui hi", agents: Self.all, current: "a-yui"), "not the agent you're in")
    }

    func testTheRowOnTheWire() {
        XCTAssertEqual(Mentions.body("@Coach does this fit?", to: Self.coach), "[yui] mention to=coach\n@Coach does this fit?")
        let meta = Mentions.meta(.object(["photos": .array([.string("p")])]), to: Self.coach)
        XCTAssertEqual(meta.object?["mention"], .object(["to": .string("a-coach"), "handle": .string("coach"), "name": .string("Coach")]))
        XCTAssertNotNil(meta.object?["photos"], "photos ride along")
        XCTAssertEqual(Mentions.to(meta: meta), "Coach")
        XCTAssertEqual(Mentions.words(body: "[yui] mention to=coach\n@Coach does this fit?", meta: meta), "@Coach does this fit?")
        XCTAssertEqual(Mentions.words(body: "[yui] mention to=coach\nhi", meta: nil), "[yui] mention to=coach\nhi",
                       "no meta: not ours, drawn as is")
    }

    func testAMentionThatArrivedFromAnotherThread() {
        let body = "[yui] mention from=yui by=person msg=m1\nYui's thread, just before:\n> Person: Plan legs\n> Yui: Here [screen]\n@Coach does this fit?"
        XCTAssertEqual(Mentions.arrivedWords(body: body), "@Coach does this fit?")
        XCTAssertEqual(Mentions.arrivedWords(body: "[yui] mention from=yui by=agent msg=m1\nAsking @coach"), "Asking @coach")
        let person: YLValue = .object(["mentioned": .object(["from_name": .string("Yui"), "by": .string("person")])])
        let agent: YLValue = .object(["mentioned": .object(["from_name": .string("Yui"), "by": .string("agent")])])
        XCTAssertEqual(Mentions.arrived(meta: person), "You, from Yui's thread")
        XCTAssertEqual(Mentions.arrived(meta: agent), "From Yui")
        let m = ChatStore.userMessage(id: "r1", body: body, meta: person)
        XCTAssertEqual(m.text, "@Coach does this fit?")
        XCTAssertEqual(m.mentionTo, "You, from Yui's thread")
    }

    func testTwoRowsSizeToTheirRows() {
        // Two agents: the popover is as tall as its rows, not the four-row cap.
        func height(_ n: Int) -> CGFloat {
            let items = Array(Mentions.suggestions("@", agents: Self.all, current: "a-yui").prefix(n))
            let host = UIHostingController(rootView: SuggestionPopover(items: items, pick: { _ in }).frame(width: 360))
            return host.sizeThatFits(in: CGSize(width: 360, height: 800)).height
        }
        let two = height(2), three = height(3)
        XCTAssertLessThan(two, 180, "two rows: \(two)")
        XCTAssertGreaterThan(three, two, "a third row makes it taller")
    }

    func testAnotherAgentsAnswerHere() {
        let store = ChatStore(messages: [])
        store.load([
            ThreadRow(id: "u1", sender: "user", body: "[yui] mention to=coach\n@Coach does this fit?", kind: "text",
                      meta: Mentions.meta(nil, to: Self.coach), createdAt: "2026-09-25T10:00:00+00:00",
                      deliveredAt: "2026-09-25T10:00:00+00:00", handledAt: "2026-09-25T10:00:00+00:00"),
            ThreadRow(id: "m1", sender: "agent", body: "Swap squats for box squats.\n```yui\nask b1 \"Swap?\" Yes|No\n```",
                      kind: "text", meta: .object(["mention_reply": .object(["agent": .string("A-COACH"), "name": .string("Coach"),
                                                                              "msg": .string("x")])]),
                      createdAt: "2026-09-25T10:00:05+00:00"),
        ])
        XCTAssertEqual(store.messages.map(\.text), ["@Coach does this fit?", "Swap squats for box squats.",
                                                    "Sent a screen. It's in Coach's thread."])
        XCTAssertEqual(store.messages[0].mentionTo, "To Coach")
        XCTAssertEqual(store.messages[1].from, MentionFrom(agentID: "a-coach", name: "Coach"))
        XCTAssertTrue(store.messages.allSatisfy { $0.yl == nil }, "its screens stay in its own thread")
        XCTAssertFalse(store.waiting, "a handled mention doesn't wait on this agent")
        let status: YLValue = .object(["mention_reply": .object(["agent": .string("a-nova"), "name": .string("Nova"),
                                                                 "status": .string("asleep")])])
        XCTAssertEqual(Mentions.from(meta: status)?.status, "asleep")
    }
}
