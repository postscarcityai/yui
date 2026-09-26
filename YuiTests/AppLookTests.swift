import SwiftUI
import XCTest
import YuiLines
@testable import Yui

/// Yui's own look (YUI-96, spec yuigui/spec/RESTYLE.md): what a `theme app` line
/// offers, what the card says the guard moved, and the store's one-step Undo.
@MainActor
final class AppLookTests: XCTestCase {
    private func props(_ line: String) -> [String: String] {
        let node = YuiLines.parse(line).first!
        XCTAssertEqual(node.op, .theme, line)
        return (node.props ?? [:]).compactMapValues { $0.string }
    }

    func testTheLineIsAnOfferNotTheAgentsLook() {
        let screen = YLScreen("say Autumn?\ntheme app autumn")
        XCTAssertEqual(screen.restyle?["name"], "autumn")
        XCTAssertTrue(screen.looks.isEmpty, "an app theme restyled the agent")
        XCTAssertFalse(screen.isBlank)
        // Several in one reply: the last one is the card.
        XCTAssertEqual(YLScreen("theme app ocean\ntheme app mint").restyle?["name"], "mint")
        // An agent's own theme is untouched.
        XCTAssertNil(YLScreen("theme autumn").restyle)
        XCTAssertEqual(YLScreen("theme autumn").looks.count, 1)
    }

    func testWhatALineOffers() {
        XCTAssertEqual(AppLook.offered(props("theme app autumn"), on: nil), AgentLook(preset: "autumn"))
        // A set starts fresh, even over another look.
        XCTAssertEqual(AppLook.offered(props("theme app ocean font=serif"), on: AgentLook(preset: "autumn", radius: "square")),
                       AgentLook(preset: "ocean", font: "serif"))
        // Keys alone change only what they say.
        XCTAssertEqual(AppLook.offered(props("theme app font=mono"), on: AgentLook(preset: "autumn")),
                       AgentLook(preset: "autumn", font: "mono"))
        // A set name as a color, a paper by name.
        XCTAssertEqual(AppLook.offered(props("theme app accent=lemon bg=sand"), on: nil),
                       AgentLook(accent: "#E5B800", bg: "#F7F0E6"))
        XCTAssertNil(AppLook.offered(props("theme app reset"), on: AgentLook(preset: "autumn")))
        XCTAssertEqual(AppLook.theme(nil), .yui)
    }

    func testTheCardNamesWhatTheGuardMoved() {
        let yellow = props("theme app accent=#FFE600")
        XCTAssertEqual(AppLook.guardNote(AppLook.offered(yellow, on: nil), props: yellow),
                       "Your color was darkened so text on buttons stays readable.")
        let mono = props("theme app mono")
        XCTAssertEqual(AppLook.guardNote(AppLook.offered(mono, on: nil), props: mono),
                       "In dark mode mono was lightened so it stands out.")
        let reset = props("theme app reset")
        XCTAssertNil(AppLook.guardNote(AppLook.offered(reset, on: nil), props: reset))
        // Every set as an app look holds AA in light and dark (the guard ran).
        for (name, _) in AgentLook.sets where name != "yui" {
            let t = AppLook.theme(AgentLook(preset: name))
            for p in [t.light, t.dark] {
                XCTAssertGreaterThanOrEqual(RGB.contrast(RGB(hex: p.ink)!, RGB(hex: p.background)!), 4.5, name)
                XCTAssertGreaterThanOrEqual(RGB.contrast(RGB(hex: p.onAccent)!, RGB(hex: p.accent)!), 4.5, name)
                XCTAssertGreaterThanOrEqual(RGB.contrast(RGB(hex: p.accent)!, RGB(hex: p.background)!), 3, name)
            }
        }
    }

    func testStoredShape() {
        let s = AppLookState(look: AgentLook(preset: "autumn", font: "serif"), prev: AgentLook(preset: "ocean"),
                             agentsKeepLooks: false, via: "Coach", at: "2026-09-25T20:00:00Z")
        let json = s.json!
        XCTAssertEqual(json["preset"] as? String, "autumn")
        XCTAssertEqual((json["prev"] as? [String: Any])?["preset"] as? String, "ocean")
        XCTAssertEqual(json["agents_keep_looks"] as? Bool, false)
        XCTAssertEqual(AppLookState(json: json), s)
        XCTAssertNil(AppLookState.yui.json, "Yui's own look is stored as null")
        XCTAssertEqual(AppLookState(json: nil), .yui)
        // Back to Yui's look from Settings keeps an Undo to the look before: prev {}.
        let back = AppLookState(look: nil, prev: AgentLook())
        XCTAssertEqual(AppLookState(json: back.json), back)
    }

    func testApplyUndoKeepReset() {
        let defaults = UserDefaults(suiteName: "AppLookTests")!
        defaults.removePersistentDomain(forName: "AppLookTests")
        let store = AppLookStore(defaults: defaults)
        var saved: [AppLookState] = []
        store.save = { saved.append($0) }

        store.apply(props("theme app autumn"), card: "r1#0", via: "Coach")
        XCTAssertEqual(store.state.look, AgentLook(preset: "autumn"))
        XCTAssertEqual(store.state.via, "Coach")
        XCTAssertEqual(store.cards["r1#0"], "applied")
        XCTAssertEqual(store.undoCard, "r1#0")
        XCTAssertNotEqual(store.theme, .yui)

        store.apply(props("theme app radius=square"), card: "r2#0", via: "Coach")
        XCTAssertEqual(store.state.look, AgentLook(preset: "autumn", radius: "square"))
        XCTAssertEqual(store.undoCard, "r2#0", "only the newest apply can be undone")

        store.undo(card: "r1#0")
        XCTAssertEqual(store.state.look?.radius, "square", "an older card's Undo did something")
        store.undo(card: "r2#0")
        XCTAssertEqual(store.state.look, AgentLook(preset: "autumn"))
        XCTAssertNil(store.state.prev, "Undo is one step, never a history")
        XCTAssertEqual(store.cards["r2#0"], "undone")

        store.keep(card: "r3#0")
        XCTAssertEqual(store.cards["r3#0"], "kept")

        // The cache brings it all back on the next launch, before the account answers.
        let again = AppLookStore(defaults: defaults)
        XCTAssertEqual(again.state.look, AgentLook(preset: "autumn"))
        XCTAssertEqual(again.cards["r2#0"], "undone")

        store.reset()
        XCTAssertNil(store.state.look)
        XCTAssertEqual(store.theme, .yui)
        store.setAgentsKeepLooks(false)
        XCTAssertFalse(store.state.agentsKeepLooks)

        // The account's copy wins over the cache.
        store.loaded(["preset": "mint", "agents_keep_looks": true])
        XCTAssertEqual(store.state.look, AgentLook(preset: "mint"))
        XCTAssertTrue(store.state.agentsKeepLooks)

        store.clear()
        XCTAssertEqual(store.state, .yui)
        let deadline = Date.now.addingTimeInterval(1)
        while saved.count < 5, Date.now < deadline { RunLoop.main.run(until: .now.addingTimeInterval(0.05)) }
        XCTAssertEqual(saved.count, 5, "every tap writes the account; keep and loads do not")
    }

    /// A thread's look: agents keep theirs unless the switch is off; Yui's own follows the app.
    func testWhatAThreadWears() {
        let defaults = UserDefaults(suiteName: "AppLookTests2")!
        defaults.removePersistentDomain(forName: "AppLookTests2")
        let store = AppLookStore(defaults: defaults)
        store.apply(props("theme app autumn"), card: "c", via: nil)
        let app = store.theme
        let wizard = YuiAgent(id: "w", name: "Wizard", handle: "wizard", color: "lavender", kind: "hermes",
                              status: .connected, isDefault: false, sort: 1)
        var yui = YuiAgent(id: "y", name: "Yui", handle: "yui", color: "brand", avatar: "yui", kind: "hermes",
                           status: .connected, isDefault: true, sort: 0)
        XCTAssertEqual(AgentThemed<EmptyView>.thread(wizard, app: app, looks: store), wizard.yuiTheme)
        XCTAssertEqual(AgentThemed<EmptyView>.thread(yui, app: app, looks: store), app)
        yui.theme = AgentLook(preset: "mint")
        XCTAssertEqual(AgentThemed<EmptyView>.thread(yui, app: app, looks: store), yui.yuiTheme, "Yui's own pick lost")
        store.setAgentsKeepLooks(false)
        XCTAssertEqual(AgentThemed<EmptyView>.thread(wizard, app: app, looks: store), app)
    }
}
