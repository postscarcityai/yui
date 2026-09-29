import Foundation
import YuiLines

// Every agent's own quiet visual (YUI-180, spec yuigui/spec/VISUAL.md section 6). Chris,
// Sep 28: "all agents should have their own visualizer by default ... make sure they are
// subtle". The list (yui-agents) sends each native agent's pick as `visual`; the crew's
// table here covers the demo account and older servers, the orb covers every other agent.
// The rule is `stageVisual` in visual.mjs and the runtime's visual.ts.

/// A default as the list sends it: look, what it hears, how strong and how fast. Never full, never quick.
struct VisualDefault: Codable, Equatable, Sendable {
    var look: String
    var hears: String
    var strength: String
    var pace: String
    var tone: String? = nil

    /// A quiet default's strength: `dim` is what any visual has behind words, `faint` lower still.
    static let strengths = ["dim": 0.7, "faint": 0.45]
    var level: Double { min(Self.strengths[strength] ?? Self.strengths["faint"]!, Self.strengths["dim"]!) }
    /// The visual's own pace, or slow: a default never runs quick.
    var motionPace: MotionLook.Pace { MotionLook.Pace(rawValue: pace).flatMap { $0 == .quick ? nil : $0 } ?? .slow }
    var line: YLVisual { YLVisual(look: look, tone: tone, react: hears) }

    /// Every other agent: the soft orb.
    static let fallback = VisualDefault(look: "orb", hears: "voice", strength: "faint", pace: "slow")

    /// The crew's picks (runtime/profiles/<name>/profile.json `visual`, the source).
    static let crew: [String: VisualDefault] = [
        "yui": .init(look: "orb", hears: "voice", strength: "dim", pace: "slow"),
        "arnold": .init(look: "waves", hears: "music", strength: "dim", pace: "even"),
        "basil": .init(look: "bloom", hears: "voice", strength: "dim", pace: "slow"),
        "gouda": .init(look: "grain", hears: "music", strength: "dim", pace: "even"),
        "penny": .init(look: "aurora", hears: "off", strength: "faint", pace: "slow"),
        "quill": .init(look: "orb", hears: "voice", strength: "faint", pace: "slow"),
    ]

    /// What an agent draws with nothing else set: the list's pick, else its crew pick, else the orb.
    static func of(_ agent: YuiAgent?) -> VisualDefault {
        guard let agent else { return .fallback }
        return agent.visual ?? (agent.kind == "hosted" ? crew[agent.handle] : nil) ?? .fallback
    }
}

/// What the stage draws for a thread.
enum StageVisualChoice: Equatable {
    case none
    /// The agent's own `visual` line: as asked, at full strength.
    case said(YLVisual)
    /// Its default, quiet.
    case quiet(VisualDefault)

    /// The one rule: the person's switch (off beats everything), then the agent's newest
    /// `visual` line (`visual off` is nothing and sticks), then its default.
    static func choose(default def: VisualDefault, said: YLVisual?, saidAny: Bool, personOff: Bool) -> StageVisualChoice {
        if personOff { return .none }
        if saidAny { return said.map { .said($0) } ?? .none }
        return .quiet(def)
    }
}

/// Settings > the agent > Visualizer: on for everyone until a person switches it off, kept per agent on the phone.
enum VisualSwitch {
    static func key(_ agentID: String) -> String { "yuiVisualOff-\(agentID)" }

    static func isOff(_ agentID: String, in d: UserDefaults = .standard) -> Bool { d.bool(forKey: key(agentID)) }

    static func set(on: Bool, for agentID: String, in d: UserDefaults = .standard) {
        if on { d.removeObject(forKey: key(agentID)) } else { d.set(true, forKey: key(agentID)) }
    }
}
