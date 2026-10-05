import Foundation

/// What a screen beside the chat is called (Chris, build feedback Oct 5: "Screen 2" means
/// nothing). Its saved name, else the first title on it, else a word for what it holds.
/// "Screen N" never shows.
enum ScreenName {
    static let maxLength = 22

    /// `saved` is the `save` name, `titles` the page's title-ish props in order (title, q, label),
    /// `kinds` the presets on it in order.
    static func pick(saved: String?, titles: [String], kinds: [String]) -> String {
        if let s = clean(saved) { return s }
        if let t = titles.lazy.compactMap({ clean($0) }).first { return t }
        if let k = kinds.lazy.compactMap({ word[$0] }).first { return k }
        return "Page"
    }

    /// A saved name reads as words: `this-week` -> "This week".
    private static func clean(_ raw: String?) -> String? {
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains(" ") { s = s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ") }
        s = s.prefix(1).uppercased() + s.dropFirst()
        return s.count > maxLength ? String(s.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…" : s
    }

    private static let word: [String: String] = [
        "list": "List", "table": "Table", "timer": "Timer", "stat": "Numbers", "chart": "Chart", "card": "Card",
        "timeline": "Timeline", "sketch": "Sketch", "shapes": "Diagram", "diagram": "Diagram", "mock": "Mock",
        "map": "Map", "image": "Photo", "gallery": "Photos", "video": "Video", "deck": "Deck", "plan": "Plan",
        "choose": "Question", "pick": "Question", "ask": "Question", "form": "Form", "slide": "Question",
        "game": "Game", "loop": "Beat", "drums": "Pads", "keys": "Keys", "chords": "Chords", "tuner": "Tuner",
        "metronome": "Metronome", "math": "Math", "calc": "Calculator", "compare": "Compare", "storyboard": "Storyboard",
        "say": "Note", "camera": "Camera", "mic": "Voice",
    ]
}
