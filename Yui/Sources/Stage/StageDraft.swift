import Foundation
import YuiLines

/// What the phone keeps of the stage's questions screen until Send: each question's answer, by the
/// question's id (message id + place in it). A relaunch, another thread and back, a new home all
/// come back to the same typed words. Secret-looking fields are never written. Under `yui.runner.`
/// so a UI test's runner reset clears it too.
struct StageDraft: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var id: String
        var value: [String: YLValue]
        var at: Date
    }

    var entries: [Entry] = []

    static let key = "yui.runner.stage"
    /// Questions nobody sent are not kept for ever.
    static let cap = 40

    @MainActor static func load(in d: UserDefaults = .standard) -> StageDraft {
        RunnerProgress.resetIfAsked()
        return d.data(forKey: key).flatMap { try? JSONDecoder().decode(StageDraft.self, from: $0) } ?? StageDraft()
    }

    private func save(in d: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }

    /// The kept answer of a question, if any.
    @MainActor static func value(_ id: String, in d: UserDefaults = .standard) -> [String: YLValue]? {
        load(in: d).entries.first { $0.id == id }?.value
    }

    /// Keeps `e` for question `id`; an answer with nothing left in it takes the kept one away.
    @MainActor static func keep(_ id: String, _ e: YLEvent, in d: UserDefaults = .standard) {
        var s = load(in: d)
        s.entries.removeAll { $0.id == id }
        let value = scrub(e.value)
        if let a = YLComponent.answerValue(YLEvent(id: e.id, preset: e.preset, value: value)), a != .object([:]), a != .string(""),
           a != .array([]) {
            s.entries.append(Entry(id: id, value: value, at: Date()))
            if s.entries.count > cap { s.entries = Array(s.entries.sorted { $0.at < $1.at }.suffix(cap)) }
        }
        s.save(in: d)
    }

    /// Sent: the questions' answers are no longer a draft.
    @MainActor static func clear(_ ids: [String], in d: UserDefaults = .standard) {
        var s = load(in: d)
        s.entries.removeAll { ids.contains($0.id) }
        s.save(in: d)
    }

    // MARK: secrets

    /// A field called key, password, code, PIN and the like, or a word shaped like a key.
    static func isSecretName(_ name: String) -> Bool {
        var spaced = ""
        var last: Character = " "
        for ch in name {
            if ch.isUppercase, last.isLowercase { spaced.append(" ") }
            spaced.append(ch.isLetter || ch.isNumber ? ch : " ")
            last = ch
        }
        let words = spaced.lowercased().split(separator: " ").map(String.init)
        let secret: Set<String> = ["key", "keys", "apikey", "password", "passwords", "passcode", "passwd", "pwd", "pass", "pin", "code",
                                   "otp", "secret", "token", "cvv", "cvc", "ssn"]
        return words.contains { secret.contains($0) }
    }

    /// `v` without any field named like a secret and without any word shaped like a key.
    static func scrub(_ v: [String: YLValue]) -> [String: YLValue] {
        var out: [String: YLValue] = [:]
        for (k, x) in v where !isSecretName(k) {
            if let y = scrub(x) { out[k] = y }
        }
        return out
    }

    private static func scrub(_ v: YLValue) -> YLValue? {
        switch v {
        case .string(let s): return KeyShape.find(in: s) == nil ? v : nil
        case .array(let a): return .array(a.compactMap(scrub))
        case .object(let o): return .object(scrub(o))
        default: return v
        }
    }
}
