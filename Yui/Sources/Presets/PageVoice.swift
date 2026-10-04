import SwiftUI
import YuiLines

extension EnvironmentValues {
    /// Set where the stage's bar (+, T, mic) sits beside a page: the page's form takes what the
    /// mic hears instead of drawing a mic of its own (t_7d424132, TestFlight AF-LecIdpo5GenYXnYNhdm0).
    @Entry var ylPageVoice: PageVoice? = nil
    /// A plan keeps every step mounted; only the one on show takes the voice.
    @Entry var ylStepActive = true
}

/// What the stage's mic hands to the page on show. The page registers what it can fill; words
/// said while it is up become a `Fill` the page applies. The request lives here, not in the page,
/// because the page unmounts while the mic listens and remounts when it stops.
@Observable @MainActor
final class PageVoice {
    enum Page {
        case form(id: String, fields: [FormField], current: [String: YLValue])
        case words(id: String, current: String)
    }

    struct Fill: Equatable {
        let id: String
        let serial: Int
        var values: [String: YLValue] = [:]
        var words: String?
    }

    @ObservationIgnored private(set) var page: Page?
    @ObservationIgnored private var serial = 0
    /// The mic is open: the page under it is unmounted, not gone.
    @ObservationIgnored var listening = false
    var fill: Fill?

    var id: String? {
        switch page {
        case .form(let id, _, _), .words(let id, _): id
        case nil: nil
        }
    }

    func register(_ p: Page) {
        page = p
        let me: String? = switch p {
        case .form(let id, _, _), .words(let id, _): id
        }
        if fill?.id != me { fill = nil }
    }

    /// The page left. Not while the mic listens: the page comes back when it stops.
    func clear(_ id: String) {
        guard !listening, self.id == id else { return }
        page = nil
        fill = nil
    }

    func reset() { page = nil; fill = nil }

    func consume(_ f: Fill) { if fill == f { fill = nil } }

    /// Spoken words for the page on show. False: nothing to fill, the words go to the agent.
    func hear(_ words: String) -> Bool {
        switch page {
        case .form(let id, let fields, let current)?:
            let got = VoiceFill.fill(words, into: fields, current: current)
            guard !got.isEmpty else { return false }
            serial += 1
            fill = Fill(id: id, serial: serial, values: got)
            return true
        case .words(let id, _)?:
            let t = words.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return false }
            serial += 1
            fill = Fill(id: id, serial: serial, words: t)
            return true
        case nil:
            return false
        }
    }
}
