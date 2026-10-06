import Foundation
import Observation
import YuiLines

// Films on the phone (spec/MOTION.md section 0.5). A film arrives as parts: the plugin sends part 1 with
// scene 1 the moment it is written, then each next scene as its own row, the last one marked `last`.
// A row is a `motion` block; ChatStore hands every one here as the thread loads, so the player can start
// at scene 1 while the rest is still coming. Scenes are the JavaScript bodies the player runs.

/// `=== scene <name> <seconds> ===` over JavaScript bodies, as the plugin writes them.
enum MotionFilmSource {
    static let mostScenes = 40

    /// The scenes in `source`, in order. A header the model got slightly wrong (no `scene` word, odd
    /// spacing) still reads; a block with no usable header is dropped.
    static func scenes(_ source: String) -> [MotionSceneSpec] {
        var out: [MotionSceneSpec] = []
        var name: String?
        var dur = 5.0
        var body: [String] = []
        func flush() {
            if let n = name {
                let code = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty, out.count < mostScenes { out.append(MotionSceneSpec(name: n, dur: dur, code: code)) }
            }
            body = []
        }
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if let h = header(String(line)) { flush(); name = h.name; dur = h.dur } else if name != nil { body.append(String(line)) }
        }
        flush()
        return out
    }

    /// `=== scene dive 6 ===` or `=== dive 6 ===`.
    static func header(_ line: String) -> (name: String, dur: Double)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("==="), t.hasSuffix("===") else { return nil }
        var parts = t.dropFirst(3).dropLast(3).split(separator: " ").map(String.init)
        if parts.first == "scene" { parts.removeFirst() }
        guard parts.count >= 2, let d = Double(parts[parts.count - 1]) else { return nil }
        let name = parts.dropLast().joined(separator: "-")
        guard !name.isEmpty else { return nil }
        return (name, min(20, max(0.5, d)))
    }
}

/// One film, its parts joined.
struct MotionFilm: Equatable {
    var id: String
    var title: String
    /// part number -> its scenes
    var parts: [Int: [MotionSceneSpec]] = [:]
    var lastPart: Int?
    /// The first part reached the phone while the person was here (not history).
    var arrivedLive = false
    var firstSeen = Date()

    /// Scenes in order, from the first part we have up to the first gap: a part that has not arrived yet
    /// holds the film at the end of what is known, as the player does.
    var scenes: [MotionSceneSpec] {
        guard let first = parts.keys.min() else { return [] }
        var out: [MotionSceneSpec] = []
        var n = first
        while let p = parts[n] { out += p; n += 1 }
        return out
    }

    /// Every part up to the last has come.
    var complete: Bool {
        guard let last = lastPart, let first = parts.keys.min() else { return false }
        return (first...last).allSatisfy { parts[$0] != nil }
    }

    /// The `say` lines, in order, as plain words (the older-phone fallback, VoiceOver's label).
    var words: [String] {
        var out: [String] = []
        for s in scenes {
            let re = try? NSRegularExpression(pattern: #"api\.say\(\s*(['"])(.*?)\1"#)
            let ns = s.code as NSString
            for m in re?.matches(in: s.code, range: NSRange(location: 0, length: ns.length)) ?? [] { out.append(ns.substring(with: m.range(at: 2))) }
        }
        return out
    }
}

@Observable @MainActor
final class MotionFilms {
    static let shared = MotionFilms()
    private(set) var films: [String: MotionFilm] = [:]
    /// Films that opened full screen by themselves already (once each).
    private var opened: Set<String> = []

    /// A `motion` row: part `part` of film `film`, its scenes in `source`. Idempotent: the thread reloads.
    func receive(film id: String, title: String, part: Int, last: Bool, source: String, live: Bool) {
        var f = films[id] ?? MotionFilm(id: id, title: title)
        if f.parts[part] == nil { f.parts[part] = MotionFilmSource.scenes(source) }
        if !title.isEmpty { f.title = title }
        if last { f.lastPart = max(f.lastPart ?? 0, part) }
        if part == (f.parts.keys.min() ?? part), live { f.arrivedLive = true }
        films[id] = f
    }

    func film(_ id: String) -> MotionFilm? { films[id] }

    /// A film that arrived live opens full screen once; history and reloads do not.
    func shouldAutoOpen(_ id: String) -> Bool {
        guard let f = films[id], f.arrivedLive, !opened.contains(id), Date().timeIntervalSince(f.firstSeen) < 120 else { return false }
        opened.insert(id)
        return true
    }

    /// Reads `motion` nodes (an add, then its patch with `source`) from a parsed reply. A head with no scene
    /// under it is a part with no scenes: the closing part, `+last`, that says the film is whole.
    func take(_ nodes: [YLNode], live: Bool) {
        var heads: [(id: String, props: [String: YLValue])] = []
        var sources: [String: String] = [:]
        for n in nodes {
            if n.op == .add, n.preset == "motion", let id = n.id { heads.append((id, n.props ?? [:])) }
            if n.op == .patch, let t = n.target, let src = n.props?["source"]?.string { sources[t] = src }
        }
        for h in heads {
            receive(film: h.props["film"]?.string ?? h.id, title: h.props["title"]?.string ?? "", part: Int(h.props["part"]?.number ?? 1),
                    last: h.props["last"] != nil, source: sources[h.id] ?? "", live: live)
        }
    }
}
