import AVFoundation
import SwiftUI
import YuiLines

// Learn and plan (YUI-19, spec yuigui/spec/YL.md "Groups"): `deck` with its
// `page` and quiz members, `plan` with its questions, `project`, and
// `narrate`, a spoken walkthrough. A group head draws its members; the
// parser marks them with the head's id (`inGroup`).

extension EnvironmentValues {
    /// True inside the stage, where a deck is already full screen.
    @Entry var ylOnStage = false
}

extension YLComponent {
    /// A quiz's right answer(s): `answer=` is always text; a pick's is a list.
    var quizAnswer: [String]? {
        props["answer"].flatMap { v in v.array.map { $0.compactMap { $0.string ?? $0.number.map(YLComponent.format) } } ?? v.string.map { [$0] } }
    }

    /// What a question step answered, as the value its own event carries.
    static func answerValue(_ e: YLEvent) -> YLValue? {
        for k in ["answer", "choice", "picked", "value", "form", "transcript", "photo"] { if let v = e.value[k] { return v } }
        return nil
    }

    /// A short, human line for an answer value.
    static func answerText(_ v: YLValue?) -> String {
        switch v {
        case .string(let s): s
        case .number(let n): format(n)
        case .bool(let b): b ? "Yes" : "No"
        case .array(let a): a.map { answerText($0) }.joined(separator: ", ")
        case .object(let o): o.keys.sorted().map { "\($0): \(answerText(o[$0]))" }.joined(separator: ", ")
        default: "Skipped"
        }
    }

    /// The question a step asks, for plan review and narration.
    var prompt: String {
        string("q") ?? string("label") ?? string("title") ?? string("prompt") ?? preset.capitalized
    }
}

/// Graded quiz feedback under an ask, choose or pick with `answer=`.
struct QuizMark: View {
    let right: Bool
    let answer: [String]
    let why: String?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            Label(right ? "Right" : "Not quite. It's \(answer.joined(separator: ", ")).",
                  systemImage: right ? "checkmark.seal.fill" : "xmark.circle.fill")
                .font(theme.font(theme.type.body, .heavy))
                .foregroundStyle(right ? ChartPalette.good(scheme) : ChartPalette.bad(scheme))
            if let why {
                Text(why).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(.opacity)
    }
}

/// Wraps a member's events: `seen` hears every one, and `pass` decides
/// whether it also goes on to the agent (plan members stay quiet).
private func relay(_ outer: YLEmit, pass: Bool, _ seen: @escaping @MainActor (YLEvent) -> Void) -> YLEmit {
    YLEmit { e in
        seen(e)
        if pass { outer(e) }
    }
}

// MARK: - page

/// `page title [body] [URL] points= notes= layout=cover|split|text`.
struct PagePreset: View {
    let c: YLComponent
    var standalone = false
    var showNotes = false
    @State private var viewing = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let img = YLMediaURL.url(c.string("img"))
        let points = c.strings("points") ?? []
        let hasText = c.string("body") != nil || !points.isEmpty
        let layout = c.string("layout") ?? (img == nil ? "text" : hasText ? "split" : "cover")
        let content = VStack(alignment: .leading, spacing: theme.spacing.m) {
            if layout == "cover", let img {
                MediaTile(src: img)
                    .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) {
                        if let t = c.string("title") {
                            Text(t).font(theme.font(theme.type.display, theme.strong)).foregroundStyle(.white)
                                .padding(theme.spacing.l)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .clipShape(.rect(cornerRadius: theme.radius.bubble))
                    .onTapGesture { viewing = true }
            } else {
                if layout == "split", let img {
                    MediaTile(src: img).frame(maxWidth: .infinity).frame(height: 190)
                        .clipShape(.rect(cornerRadius: theme.radius.bubble))
                        .onTapGesture { viewing = true }
                }
                if let t = c.string("title") {
                    Text(t).font(theme.font(theme.type.display - 2, theme.strong)).foregroundStyle(s.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let b = c.string("body") {
                    Text(b).font(theme.font(theme.type.body + 1, .medium)).foregroundStyle(s.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !points.isEmpty {
                    VStack(alignment: .leading, spacing: theme.spacing.s) {
                        ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.m) {
                                Circle().fill(s.candy[i % 4]).frame(width: 10, height: 10)
                                Text(p).font(theme.font(theme.type.body, .medium)).foregroundStyle(s.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if showNotes, let n = c.string("notes") {
                Text(n).font(theme.font(theme.type.caption, .medium)).foregroundStyle(s.inkSoft)
                    .padding(theme.spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(s.butter.opacity(0.35), in: .rect(cornerRadius: theme.radius.bubble / 2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fullScreenCover(isPresented: $viewing) {
            if let img { MediaViewer(items: [img], captions: [c.string("title") ?? ""], index: 0, close: { viewing = false }) }
        }
        if standalone { PresetCard { content } } else { content }
    }
}

// MARK: - deck

/// `deck [title] layout=slides|scroll +full +notes`, then pages and quiz questions.
/// Emits `{done: true, pages, score?, of?}` once every page is seen and every question answered.
struct DeckPreset: View {
    let c: YLComponent
    @State private var at = 0
    @State private var seen: Set<Int> = [0]
    @State private var graded: [Int: Bool] = [:]
    @State private var answered: Set<Int> = []
    @State private var notes: Bool?
    @State private var full = false
    @State private var sentDone = false
    @Environment(\.ylComponents) private var all
    @Environment(\.ylOnStage) private var onStage
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        DeckBody(c: c, pages: all.members(of: c), at: $at, seen: $seen, notes: notes ?? c.flag("notes"),
                 toggleNotes: { notes = !(notes ?? c.flag("notes")) }, full: full,
                 openFull: onStage ? nil : { full = true }, emit: pageEmit)
            .onChange(of: at) { seen.insert(at); checkDone() }
            .onAppear { if c.flag("full"), !onStage { full = true } }
            .fullScreenCover(isPresented: $full) {
                DeckBody(c: c, pages: all.members(of: c), at: $at, seen: $seen, notes: notes ?? c.flag("notes"),
                         toggleNotes: { notes = !(notes ?? c.flag("notes")) }, full: true, openFull: nil, emit: pageEmit,
                         close: { full = false })
                    .environment(\.ylComponents, all)
                    .fullScreenExit(x: false) { full = false }
            }
    }

    private var pageEmit: YLEmit {
        relay(emit, pass: true) { e in
            let pages = all.members(of: c)
            guard let i = pages.firstIndex(where: { $0.ylID == e.id && $0.preset == e.preset }) else { return }
            answered.insert(i)
            if let r = e.value["correct"]?.bool { graded[i] = r }
            checkDone()
        }
    }

    private func checkDone() {
        let pages = all.members(of: c)
        guard !sentDone, !pages.isEmpty, seen.count >= pages.count else { return }
        let questions = pages.indices.filter { pages[$0].preset != "page" }
        guard questions.allSatisfy(answered.contains) else { return }
        sentDone = true
        var v: [String: YLValue] = ["done": .bool(true), "pages": .number(Double(pages.count))]
        let quizzes = questions.filter { pages[$0].quizAnswer != nil }
        if !quizzes.isEmpty {
            v["score"] = .number(Double(quizzes.filter { graded[$0] == true }.count))
            v["of"] = .number(Double(quizzes.count))
        }
        emit(c.event(v))
    }
}

private struct DeckBody: View {
    let c: YLComponent
    let pages: [YLComponent]
    @Binding var at: Int
    @Binding var seen: Set<Int>
    let notes: Bool
    let toggleNotes: () -> Void
    let full: Bool
    let openFull: (() -> Void)?
    let emit: YLEmit
    var close: (() -> Void)? = nil
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let hasNotes = pages.contains { $0.string("notes") != nil }
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            HStack(spacing: theme.spacing.s) {
                if let t = c.string("title") { PresetTitle(text: t).lineLimit(2) }
                Spacer(minLength: 0)
                if hasNotes {
                    small(notes ? "Hide notes" : "Notes", "note.text", on: notes, action: toggleNotes)
                }
                if let openFull { small("Full screen", "arrow.up.left.and.arrow.down.right", action: openFull) }
                if let close { small("Close", "xmark", action: close) }
            }
            if pages.isEmpty {
                Text("Pages are on their way.").font(theme.font(theme.type.body, .medium)).foregroundStyle(s.inkSoft)
            } else if c.string("layout") == "scroll" {
                VStack(alignment: .leading, spacing: theme.spacing.xl) {
                    ForEach(Array(pages.enumerated()), id: \.element.serial) { i, p in
                        page(p).onAppear { seen.insert(i) }
                        if i < pages.count - 1 { Divider().overlay(s.outline) }
                    }
                }
            } else {
                TabView(selection: $at) {
                    ForEach(Array(pages.enumerated()), id: \.element.serial) { i, p in
                        ScrollView { page(p).padding(.bottom, theme.spacing.s) }
                            .scrollBounceBehavior(.basedOnSize)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(minHeight: full ? 480 : 380, maxHeight: full ? .infinity : 440)
                HStack {
                    arrow("chevron.left", "Previous page", disabled: at == 0) { at -= 1 }
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(pages.indices, id: \.self) { i in
                            Capsule().fill(i == at ? s.accent : seen.contains(i) ? s.inkSoft.opacity(0.5) : s.outline)
                                .frame(width: i == at ? 18 : 7, height: 7)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Page \(at + 1) of \(pages.count)")
                    Spacer()
                    arrow("chevron.right", "Next page", disabled: at >= pages.count - 1) { at += 1 }
                }
            }
        }
        .padding(theme.spacing.l)
        .frame(maxWidth: .infinity, maxHeight: full ? .infinity : nil, alignment: .top)
        .background(s.surface, in: .rect(cornerRadius: full ? 0 : theme.radius.card))
        .overlay(RoundedRectangle(cornerRadius: full ? 0 : theme.radius.card).stroke(full ? .clear : s.outline, lineWidth: 1.5))
        .background(full ? s.surface : .clear)
        .environment(\.ylEmit, emit)
        .animation(theme.spring, value: at)
    }

    @ViewBuilder
    private func page(_ p: YLComponent) -> some View {
        if p.preset == "page" {
            PagePreset(c: p, showNotes: notes)
        } else {
            PresetView(component: p)
        }
    }

    private func arrow(_ icon: String, _ label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        let s = theme.swatch(scheme)
        return Button(label, systemImage: icon, action: action)
            .labelStyle(.iconOnly)
            .font(theme.font(theme.type.body, .black))
            .foregroundStyle(disabled ? s.inkSoft : s.onAccent)
            .frame(width: 44, height: 44)
            .background(disabled ? s.background : s.accent, in: Circle())
            .buttonStyle(BounceButtonStyle())
            .disabled(disabled)
    }

    private func small(_ label: String, _ icon: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        let s = theme.swatch(scheme)
        // The circle is inside the label: drawn outside, only the glyph took taps.
        return Button(action: action) {
            Image(systemName: icon)
                .font(theme.font(theme.type.caption, .black))
                .foregroundStyle(on ? s.onAccent : s.ink)
                .frame(width: 36, height: 36)
                .background(on ? s.accent : s.background, in: Circle())
                .overlay(Circle().stroke(s.outline, lineWidth: 1.5))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - plan

/// `plan [title] submit= review=off`, then one question per step. Members send
/// nothing themselves; the plan emits `{plan: {id: answer}}` on submit.
struct PlanPreset: View {
    let c: YLComponent
    @State private var at = 0
    @State private var answers: [String: YLValue] = [:]
    @State private var reviewing = false
    @State private var submitted = false
    @Environment(\.ylComponents) private var all
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let steps = all.members(of: c)
        let review = c.props["review"]?.bool != false
        PresetCard {
            if let t = c.string("title") { PresetTitle(text: t) }
            if submitted {
                summary(steps, s)
            } else if reviewing {
                reviewList(steps, s)
            } else if steps.isEmpty {
                Text("The questions are on their way.").font(theme.font(theme.type.body, .medium)).foregroundStyle(s.inkSoft)
            } else {
                let cur = min(at, steps.count - 1)
                HStack {
                    Text("Step \(cur + 1) of \(steps.count)").font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                    Spacer()
                }
                ProgressView(value: Double(cur + 1), total: Double(steps.count)).tint(s.accent)
                // Every step stays mounted so its answer survives Back and Edit.
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.serial) { i, step in
                        PresetView(component: step)
                            .environment(\.ylEmit, relay(emit, pass: false) { e in record(e, step: step, i: i, steps: steps, review: review) })
                            .frame(height: i == cur ? nil : 0, alignment: .top)
                            .clipped()
                            .opacity(i == cur ? 1 : 0)
                            .allowsHitTesting(i == cur)
                            .accessibilityHidden(i != cur)
                    }
                }
                HStack(spacing: theme.spacing.s) {
                    OptionPill(text: "Back", fill: s.lavender, on: cur > 0, grow: true) {
                        withAnimation(theme.spring) { at = max(0, cur - 1) }
                    }
                    .disabled(cur == 0)
                    let last = cur == steps.count - 1
                    OptionPill(text: last ? (review ? "Review" : c.string("submit") ?? "Send") : "Next",
                               fill: s.accent, ink: s.onAccent, grow: true) {
                        if last { review ? withAnimation(theme.spring) { reviewing = true } : submit(steps) }
                        else { withAnimation(theme.spring) { at = cur + 1 } }
                    }
                }
            }
        }
    }

    private func record(_ e: YLEvent, step: YLComponent, i: Int, steps: [YLComponent], review: Bool) {
        guard let v = YLComponent.answerValue(e) else { return }
        answers[step.ylID] = v
        // ask and choose move on by themselves after a tap.
        guard step.preset == "ask" || step.preset == "choose" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(theme.spring) {
                if i < steps.count - 1 { at = i + 1 }
                else if review { reviewing = true }
            }
            if i == steps.count - 1, !review { submit(steps) }
        }
    }

    private func reviewList(_ steps: [YLComponent], _ s: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            ForEach(Array(steps.enumerated()), id: \.element.serial) { i, step in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.prompt).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                        Text(YLComponent.answerText(answers[step.ylID]))
                            .font(theme.font(theme.type.body, .bold))
                            .foregroundStyle(answers[step.ylID] == nil ? s.inkSoft : s.ink)
                    }
                    Spacer()
                    Button("Edit") {
                        withAnimation(theme.spring) { at = i; reviewing = false; submitted = false }
                    }
                    .font(theme.font(theme.type.caption, .heavy))
                    .foregroundStyle(s.ink)
                    .accessibilityLabel("Edit \(step.prompt)")
                }
            }
            OptionPill(text: c.string("submit") ?? "Send", fill: s.accent, ink: s.onAccent, grow: true) { submit(steps) }
        }
    }

    private func summary(_ steps: [YLComponent], _ s: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            Label("Sent", systemImage: "checkmark.circle.fill").font(theme.font(theme.type.body, .heavy))
                .foregroundStyle(ChartPalette.good(scheme))
            ForEach(steps.filter { answers[$0.ylID] != nil }, id: \.serial) { step in
                Text("\(step.prompt): \(YLComponent.answerText(answers[step.ylID]))")
                    .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.ink)
            }
            OptionPill(text: "Edit answers", fill: s.lavender, grow: true) {
                withAnimation(theme.spring) { submitted = false; reviewing = true }
            }
        }
    }

    private func submit(_ steps: [YLComponent]) {
        var plan: [String: YLValue] = [:]
        for step in steps { if let v = answers[step.ylID] { plan[step.ylID] = v } }
        emit(c.event(["plan": .object(plan)], echo: c.string("title").map { "Plan sent: \($0)" } ?? "Plan sent"))
        withAnimation(theme.spring) { submitted = true; reviewing = false }
    }
}

// MARK: - project

/// `project title [body] status= progress= facts="Label: value|..." next=a|b img= open= cta=`.
struct ProjectPreset: View {
    let c: YLComponent
    @Environment(\.ylShow) private var show
    @Environment(\.ylScope) private var scope
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        PresetCard {
            if let img = YLMediaURL.url(c.string("img")) {
                RemoteImage(src: img).frame(height: 150).frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: theme.radius.bubble))
            }
            HStack(alignment: .firstTextBaseline) {
                if let t = c.string("title") { PresetTitle(text: t) }
                Spacer(minLength: theme.spacing.s)
                if let st = c.string("status") {
                    Text(st).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.userInk)
                        .padding(.horizontal, theme.spacing.s).padding(.vertical, 3).background(s.mint, in: Capsule())
                }
            }
            if let b = c.string("body") {
                Text(b).font(theme.font(theme.type.body)).foregroundStyle(s.ink).fixedSize(horizontal: false, vertical: true)
            }
            if let p = c.number("progress") {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: min(max(p, 0), 100), total: 100).tint(s.accent)
                    Text("\(YLComponent.format(p))%").font(theme.font(theme.type.caption, .bold).monospacedDigit()).foregroundStyle(s.inkSoft)
                }
            }
            if let facts = c.strings("facts"), !facts.isEmpty {
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                        let parts = f.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        HStack(alignment: .firstTextBaseline) {
                            Text(parts[0]).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                            Spacer()
                            if parts.count > 1 { Text(parts[1]).font(theme.font(theme.type.body, .semibold)).foregroundStyle(s.ink) }
                        }
                    }
                }
            }
            if let next = c.strings("next"), !next.isEmpty {
                Text("Next").font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                ForEach(Array(next.enumerated()), id: \.offset) { i, n in
                    Label(n, systemImage: "arrow.right.circle").font(theme.font(theme.type.body, .medium)).foregroundStyle(s.ink)
                }
            }
            let open = c.string("open")
            if let label = c.string("cta") ?? (open != nil ? "Open" : nil) {
                OptionPill(text: label, fill: s.accent, ink: s.onAccent, grow: true) {
                    if let open {
                        show(scope: scope, screen: c.screen, name: open)
                        emit(c.event(["open": .string(open)], echo: label))
                    } else {
                        emit(c.event(["cta": .string(label)], echo: label))
                    }
                }
            }
        }
        .disabled(c.locked)
    }
}

// MARK: - narrate

/// One spoken step: what shows and what is said.
private struct NarrateStep {
    let member: YLComponent
    /// Which page, frame or gallery item, for members with several steps.
    let part: Int?
    let say: String
    /// A quiz page waits for its answer before the walkthrough goes on.
    let question: Bool
}

/// Speaks one line at a time and reports which word it is on.
@Observable @MainActor
final class Narrator: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var word: NSRange?
    var speaking = false
    /// Bumped each time a line finishes on its own; the view moves on then.
    var finishes = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Double) {
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * rate, Double(AVSpeechUtteranceMinimumSpeechRate)),
                           Double(AVSpeechUtteranceMaximumSpeechRate)))
        word = nil
        speaking = true
        synth.speak(u)
    }

    func stop() {
        speaking = false
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.word = range }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.speaking else { return }
            self.speaking = false
            self.word = nil
            self.finishes += 1
        }
    }

    /// `voice=agent` is the agent's own voice: one stable pick per agent among
    /// the most natural installed voices for the language. Else a voice by name or language.
    static func voice(_ name: String?, lang: String?, agent: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let language = lang ?? AVSpeechSynthesisVoice.currentLanguageCode()
        if let name, name != "agent" {
            if let v = voices.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return v }
            if let v = voices.first(where: { $0.language.caseInsensitiveCompare(name) == .orderedSame }) { return v }
        }
        let infos = voices.map { VoiceInfo(id: $0.identifier, language: $0.language, quality: $0.quality.rawValue,
                                           novelty: $0.voiceTraits.contains(.isNoveltyVoice),
                                           personal: $0.voiceTraits.contains(.isPersonalVoice)) }
        if let id = pick(infos, language: language, agent: agent), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return AVSpeechSynthesisVoice(language: language)
    }

    struct VoiceInfo: Equatable {
        let id: String
        let language: String
        let quality: Int
        var novelty = false
        var personal = false

        /// The old MacinTalk voices (Fred, Zarvox, Bad News) and the Eloquence
        /// set (Eddy, Grandpa, Reed) ship on every device at default quality
        /// and read as robots (TestFlight: "sounds like Stephen Hawking").
        var robotic: Bool {
            novelty || id.contains(".speech.synthesis.voice.") || id.contains(".eloquence.")
        }

        /// Premium, then enhanced, then the Siri and compact voices.
        var rank: Int {
            let siri = id.contains(".siri") || id.contains(".voice.compact.") || id.contains(".voice.super-compact.")
            return quality * 10 + (siri ? 1 : 0)
        }
    }

    /// Never a robot or the person's own Personal Voice. The best tier for the
    /// language wins; the agent's name picks within it so agents differ when
    /// several good voices are installed. Nil when nothing natural is installed.
    static func pick(_ voices: [VoiceInfo], language: String, agent: String) -> String? {
        let pool = voices.filter { $0.language == language && !$0.robotic && !$0.personal }
            .sorted { ($0.rank, $0.id) > ($1.rank, $1.id) }
        let best = pool.filter { $0.rank == pool.first?.rank }
        guard !best.isEmpty else { return nil }
        return best[agent.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % best.count].id
    }
}

/// `narrate [title] voice=agent rate=1 lang= +auto captions=off`, then the
/// things to walk through. Emits `{played: true}` once and `{done: true, steps}` at the end.
struct NarratePreset: View {
    let c: YLComponent
    @State private var narrator = Narrator()
    @State private var at = 0
    @State private var playing = false
    @State private var played = false
    @State private var answered: Set<Int> = []
    @State private var full = false
    @Environment(\.ylComponents) private var all
    @Environment(\.ylOnStage) private var onStage
    @Environment(\.ylEmit) private var emit
    @Environment(\.ylScope) private var scope
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let steps = self.steps
        stage(steps, full: false)
            .fullScreenCover(isPresented: $full) {
                stage(steps, full: true)
                    .environment(\.ylComponents, all)
                    .environment(\.ylOnStage, true)
                    .fullScreenExit(x: false) { full = false }
            }
            // Observed, not a stored callback: members stream in after the head,
            // so a closure captured on appear would see an empty walkthrough.
            .onChange(of: narrator.finishes) { advance() }
            .onAppear {
                if c.flag("auto"), !played { Task { try? await Task.sleep(for: .milliseconds(600)); play() } }
            }
            .onDisappear { narrator.stop() }
    }

    private var steps: [NarrateStep] {
        all.members(of: c).flatMap { m -> [NarrateStep] in
            switch m.preset {
            case "deck":
                return all.members(of: m).enumerated().map { i, p in
                    NarrateStep(member: m, part: i, say: said(p), question: p.preset != "page")
                }
            case "storyboard":
                let frames = m.strings("frames") ?? [], notes = m.strings("notes") ?? []
                return (0..<max(frames.count, notes.count)).map { i in
                    NarrateStep(member: m, part: i, say: i < notes.count ? notes[i] : "", question: false)
                }
            case "gallery":
                let items = m.strings("items") ?? [], caps = m.strings("caps") ?? []
                return items.indices.map { i in NarrateStep(member: m, part: i, say: i < caps.count ? caps[i] : "", question: false) }
            default:
                return [NarrateStep(member: m, part: nil, say: said(m), question: false)]
            }
        }
    }

    /// A member's `say=`, else what it shows.
    private func said(_ m: YLComponent) -> String {
        if let s = m.string("say") { return s }
        let join = { (parts: [String?]) in parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ") }
        switch m.preset {
        case "page": return m.string("notes") ?? join([m.string("title"), m.string("body")] + (m.strings("points") ?? []))
        case "compare": return join([m.string("title")] + (m.strings("notes") ?? []))
        case "card": return join([m.string("title"), m.string("body")])
        case "stat": return join([m.string("label"), m.number("value").map { YLNumber.withUnit($0, m.string("unit")) } ?? m.string("value")])
        case "ask", "choose", "pick": return join([m.string("q")] + (m.strings("options") ?? []))
        default: return join([m.string("title"), m.string("caption")])
        }
    }

    private func stage(_ steps: [NarrateStep], full: Bool) -> some View {
        let s = theme.swatch(scheme)
        let cur = min(at, max(steps.count - 1, 0))
        let step = steps.isEmpty ? nil : steps[cur]
        return VStack(alignment: .leading, spacing: theme.spacing.m) {
            HStack(spacing: theme.spacing.s) {
                Image(systemName: "waveform").foregroundStyle(s.accent).symbolEffect(.variableColor, isActive: narrator.speaking)
                if let t = c.string("title") { PresetTitle(text: t).lineLimit(2) }
                Spacer(minLength: 0)
                if full {
                    control("Close", "xmark") { self.full = false }
                } else if !onStage {
                    control("Full screen", "arrow.up.left.and.arrow.down.right") { self.full = true }
                }
            }
            // One bar per step, filled as it goes.
            HStack(spacing: 4) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule().fill(i < cur || (i == cur && at >= steps.count) ? s.accent : i == cur ? s.accent.opacity(0.55) : s.outline)
                        .frame(height: 5)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(cur + 1) of \(steps.count)")
            if let step {
                shown(step, index: cur)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .id(cur)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                if c.props["captions"]?.bool != false, !step.say.isEmpty { caption(step.say, s) }
            } else {
                Text("The walkthrough is on its way.").font(theme.font(theme.type.body, .medium)).foregroundStyle(s.inkSoft)
            }
            HStack(spacing: theme.spacing.s) {
                control("Back", "backward.fill", disabled: cur == 0) { go(cur - 1) }
                Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") { playing ? pause() : play() }
                    .labelStyle(.iconOnly)
                    .font(theme.font(theme.type.title, .black))
                    .foregroundStyle(s.onAccent)
                    .frame(width: 60, height: 60)
                    .background(s.accent, in: Circle())
                    .buttonStyle(BounceButtonStyle())
                    .disabled(steps.isEmpty)
                control("Next", "forward.fill", disabled: cur >= steps.count - 1) { go(cur + 1) }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(theme.spacing.l)
        .frame(maxWidth: .infinity, maxHeight: full ? .infinity : nil, alignment: .top)
        .background(s.surface, in: .rect(cornerRadius: full ? 0 : theme.radius.card))
        .overlay(RoundedRectangle(cornerRadius: full ? 0 : theme.radius.card).stroke(full ? .clear : s.outline, lineWidth: 1.5))
        .background(full ? s.surface : .clear)
        .animation(theme.spring, value: at)
    }

    /// The step's member, as it looks on its own; a deck shows one page, a
    /// storyboard one frame, a gallery one item.
    @ViewBuilder
    private func shown(_ step: NarrateStep, index: Int) -> some View {
        let s = theme.swatch(scheme)
        let m = step.member
        switch (m.preset, step.part) {
        case ("deck", let i?):
            let pages = all.members(of: m)
            if i < pages.count {
                if pages[i].preset == "page" {
                    PagePreset(c: pages[i])
                } else {
                    PresetView(component: pages[i])
                        .environment(\.ylEmit, relay(emit, pass: true) { _ in questionAnswered(index) })
                }
            }
        case ("storyboard", let i?), ("gallery", let i?):
            let urls = m.strings(m.preset == "gallery" ? "items" : "frames") ?? []
            if i < urls.count, let url = YLMediaURL.url(urls[i]) {
                MediaTile(src: url, fit: .fill).frame(height: 240).frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: theme.radius.bubble))
            } else {
                Text("\(i + 1)").font(theme.font(theme.type.display * 2, .black)).foregroundStyle(s.lavender)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        case ("page", _):
            PagePreset(c: m)
        default:
            PresetView(component: m)
        }
    }

    private func caption(_ text: String, _ s: Swatch) -> some View {
        var a = AttributedString(text)
        a.foregroundColor = s.inkSoft
        if let r = narrator.word, let range = Range(r, in: text), let ar = Range(range, in: a) {
            a[a.startIndex..<ar.upperBound].foregroundColor = s.ink
            a[ar].backgroundColor = s.butter
        }
        return Text(a)
            .font(theme.font(theme.type.body + 1, .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(theme.spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(s.background, in: .rect(cornerRadius: theme.radius.bubble))
            .accessibilityLabel(text)
    }

    private func control(_ label: String, _ icon: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        let s = theme.swatch(scheme)
        return Button(action: action) {
            Image(systemName: icon)
                .font(theme.font(theme.type.body, .black))
                .foregroundStyle(disabled ? s.inkSoft : s.ink)
                .frame(width: 44, height: 44)
                .background(s.background, in: Circle())
                .overlay(Circle().stroke(s.outline, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(label)
        .disabled(disabled)
    }

    private var voice: AVSpeechSynthesisVoice? {
        Narrator.voice(c.string("voice"), lang: c.string("lang"), agent: scope.split(separator: "#").first.map(String.init) ?? "")
    }

    private func speakCurrent() {
        let steps = self.steps
        guard at < steps.count else { return }
        let say = steps[at].say
        if say.isEmpty {
            // Nothing to say: hold the step a moment, then move on.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                if playing, !narrator.speaking { advance() }
            }
        } else {
            narrator.speak(say, voice: voice, rate: c.number("rate") ?? 1)
        }
    }

    private func play() {
        if !played {
            played = true
            emit(c.event(["played": .bool(true)]))
        }
        if at >= steps.count { at = 0 }
        playing = true
        speakCurrent()
    }

    private func pause() {
        playing = false
        narrator.stop()
    }

    private func go(_ i: Int) {
        withAnimation(theme.spring) { at = min(max(i, 0), max(steps.count - 1, 0)) }
        if playing { speakCurrent() } else { narrator.stop() }
    }

    /// A step finished speaking: wait on a question, else move on or finish.
    private func advance() {
        let steps = self.steps
        guard playing, at < steps.count else { return }
        if steps[at].question, !answered.contains(at) { return }
        if at == steps.count - 1 {
            playing = false
            emit(c.event(["done": .bool(true), "steps": .number(Double(steps.count))]))
            return
        }
        withAnimation(theme.spring) { at += 1 }
        speakCurrent()
    }

    private func questionAnswered(_ i: Int) {
        let first = answered.insert(i).inserted
        if first, i == at, playing, !narrator.speaking { advance() }
    }
}
