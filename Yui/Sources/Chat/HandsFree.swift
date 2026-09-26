import Foundation

// Hands-free (YUI-14, ROADMAP north star 2: talk naturally, read the answer).
// Tap the mic once and it stays open between turns: you talk, a short quiet sends
// what you said, the reply comes in as text, and the mic opens again once it lands.
// This file is the rules only: no audio, no views. ChatView feeds it events and
// carries out what it answers, so every turn of the loop is unit tested
// (YuiTests/HandsFreeTests).

struct HandsFree: Equatable {
    enum State: Equatable {
        case off
        /// Opening the mic.
        case starting
        case listening
        /// A quiet spell ended the turn: the last words are settling.
        case finishing
        /// The words are going out.
        case sending
        /// Sent; the agent owes a reply.
        case waiting
        /// The reply landed: a beat to see it before the mic opens again.
        case reading
        case paused(Pause)
    }

    enum Pause: Equatable {
        /// A call, Siri or an alarm took the mic.
        case interrupted
        /// Nobody talked for `quietLimit`.
        case quiet
        /// The mic or the recognizer wouldn't start, or the send failed.
        case failed
        /// No mic or speech permission.
        case denied
    }

    enum Event: Equatable {
        case tap
        case micOpen
        case micFailed(denied: Bool)
        /// The gate heard the end of the turn.
        case endOfSpeech
        /// The final words after `endOfSpeech`; empty means nothing worth sending.
        case heard(String)
        case sent
        case sendFailed
        case replyLanded
        case readDone
        case interrupted
        case interruptionEnded
        case quietTooLong
        case stop
    }

    /// What ChatView does next.
    enum Effect: Equatable {
        case openMic
        /// Stop listening and keep the words (then send `heard`).
        case finishMic
        /// Stop listening and throw the words away.
        case closeMic
        case send(String)
        /// Wait `readBeat`, then `readDone`.
        case readBeat
    }

    private(set) var state: State = .off

    var on: Bool { state != .off }
    /// The mic is open, or opening.
    var micOpen: Bool { state == .starting || state == .listening }

    /// The quiet after speech that ends a turn.
    static let endQuiet: TimeInterval = 0.7
    /// Listening this long with no words pauses it, so an open mic doesn't run all day.
    static let quietLimit: TimeInterval = 30
    /// After a reply lands, before the mic opens again.
    static let readBeat: Duration = .milliseconds(600)

    @discardableResult
    mutating func handle(_ e: Event) -> Effect? {
        switch (state, e) {
        case (_, .stop):
            let wasOpen = micOpen || state == .finishing
            state = .off
            return wasOpen ? .closeMic : nil
        case (.off, .tap), (.paused, .tap), (.paused(.interrupted), .interruptionEnded):
            state = .starting
            return .openMic
        case (.starting, .micOpen):
            state = .listening
        case (.starting, .micFailed(let denied)):
            state = .paused(denied ? .denied : .failed)
        case (.listening, .endOfSpeech):
            state = .finishing
            return .finishMic
        case (.listening, .quietTooLong):
            state = .paused(.quiet)
            return .closeMic
        case (.finishing, .heard(let words)):
            let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
            if words.isEmpty { state = .starting; return .openMic }
            state = .sending
            return .send(words)
        case (.sending, .sent):
            state = .waiting
        case (.sending, .sendFailed):
            state = .paused(.failed)
        case (.sending, .replyLanded), (.waiting, .replyLanded):
            state = .reading
            return .readBeat
        case (.reading, .readDone):
            state = .starting
            return .openMic
        case (.starting, .interrupted), (.listening, .interrupted), (.finishing, .interrupted):
            state = .paused(.interrupted)
            return .closeMic
        case (.waiting, .interrupted), (.reading, .interrupted), (.sending, .interrupted):
            // The words are out; the reply still comes. Only the mic waits.
            state = .paused(.interrupted)
        default:
            break
        }
        return nil
    }
}

extension HandsFree {
    /// The state as one word, for VoiceOver's value and the UI tests.
    var accessibilityState: String {
        switch state {
        case .off: "off"
        case .starting: "starting"
        case .listening: "listening"
        case .finishing: "finishing"
        case .sending: "sending"
        case .waiting: "waiting"
        case .reading: "reading"
        case .paused: "paused"
        }
    }

    #if DEBUG
    /// `-yuiHandsFreeDemo <state>`: hands-free walked to that state by its own events, for screenshots.
    static func demo(_ at: String) -> HandsFree? {
        var hf = HandsFree()
        let path: [Event] = [.tap, .micOpen, .endOfSpeech, .heard("What's on my calendar tomorrow morning?"), .sent, .replyLanded]
        let steps = ["listening": 2, "sending": 4, "waiting": 5, "reading": 6]
        if at == "paused" {
            for e in [Event.tap, .micOpen, .quietTooLong] { hf.handle(e) }
            return hf
        }
        guard let n = steps[at] else { return nil }
        for e in path.prefix(n) { hf.handle(e) }
        return hf
    }
    #endif
}

/// When the person has stopped talking: words heard, then `HandsFree.endQuiet` with
/// no new words and no voice. Noise alone never ends a turn; it needs words.
enum EndOfSpeech {
    static func ended(words: String, lastSound: Date?, now: Date = .now,
                      quiet: TimeInterval = HandsFree.endQuiet) -> Bool {
        guard words.contains(where: { !$0.isWhitespace }), let lastSound else { return false }
        return now.timeIntervalSince(lastSound) >= quiet
    }

    /// Listening with no words at all for `HandsFree.quietLimit`.
    static func tooQuiet(words: String, startedAt: Date?, now: Date = .now) -> Bool {
        guard !words.contains(where: { !$0.isWhitespace }), let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= HandsFree.quietLimit
    }
}

/// How a thread with this agent starts: talking (hands-free opens with it) or typing.
/// Kept on the phone with the agent's other local things (its shelf, its menu).
enum TalkMode: String, CaseIterable, Sendable {
    case type, talk

    static func key(_ agentID: String) -> String { "yuiTalkMode-\(agentID)" }

    static func of(_ agentID: String, in d: UserDefaults = .standard) -> TalkMode {
        d.string(forKey: key(agentID)).flatMap(TalkMode.init) ?? .type
    }

    static func set(_ m: TalkMode, for agentID: String, in d: UserDefaults = .standard) {
        if m == .type { d.removeObject(forKey: key(agentID)) } else { d.set(m.rawValue, forKey: key(agentID)) }
    }
}
