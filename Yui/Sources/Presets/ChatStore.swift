import Foundation
import Observation
import SwiftUI
import YuiLines

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var fromUser: Bool
    /// An agent reply in Yui Lines, drawn as presets instead of a bubble.
    var yl: YLScreen?
}

/// The chat's messages plus the event log going back to the agent.
@Observable @MainActor
final class ChatStore {
    var messages: [ChatMessage]
    private(set) var events: [YLEvent] = []
    var spring: Animation = .default

    init(messages: [ChatMessage] = []) { self.messages = messages }

    var emit: YLEmit { YLEmit { [weak self] e in self?.receive(e) } }

    func receive(_ e: YLEvent) {
        events.insert(e, at: 0)
        print("yl event", e.json)
        guard let echo = e.echo else { return }
        withAnimation(spring) { messages.append(ChatMessage(text: echo, fromUser: true)) }
    }

    /// Adds an agent reply and feeds it through the stream parser a line at a
    /// time, the way a model's tokens will arrive, so each preset lands on its own.
    func stream(_ text: String, lineDelay: Duration = .milliseconds(220)) {
        let msg = ChatMessage(text: "", fromUser: false, yl: YLScreen())
        withAnimation(spring) { messages.append(msg) }
        Task {
            var parser = YLStreamParser()
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                apply(parser.push(line + "\n"), to: msg.id)
                try? await Task.sleep(for: lineDelay)
            }
            apply(parser.flush(), to: msg.id)
        }
    }

    private func apply(_ nodes: [YLNode], to id: UUID) {
        guard !nodes.isEmpty, let i = messages.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(spring) {
            for n in nodes { messages[i].yl?.apply(n) }
        }
    }
}

/// Canned replies for the paste box and screenshot launch args (`-yuiYL <name>`).
enum YLSamples {
    static let all: [(name: String, text: String)] = [
        ("tabata", """
        say Tabata time. Eight rounds, 20 on and 10 off.
        timer@hiit 20/10x8 Tabata +auto
        ask "Log it when you're done?"
        """),
        ("checkin", """
        form "Daily check-in" mood:1-5 sleep_hours:number! "Trained today":yes split:Push|Pull|Legs notes:voice submit="Log it"
        """),
        ("choose", """
        choose "Which split today?" Push|Pull|Legs +other
        ask "Send the invite now?" "Yes, send"|"Not yet"
        """),
        ("gear", """
        pick "What gear do you have?" Dumbbells|Bench|Bands|"Pull-up bar"|Kettlebell +other max=3
        """),
        ("today", """
        list Today "Squat 5x5 @ 225" "Bench 5x5 @ 185" "Row 3x10" +check
        list Warmup "Jumping jacks"|"Hip openers"|"Band pull-aparts" +num
        """),
        ("tour", """
        say Here's everything I can draw so far.
        ask "Ready?"
        choose "Pick a vibe" Calm|Focused|Chaotic +other
        pick "Snacks" Tteokbokki|Kimbap|Hotteok|Bingsu
        form "Quick one" name! "Favorite number":1-10
        list Plan "Stretch" "Lift" "Nap" +check
        timer 5m Plank hold
        slide "Energy" 1-5
        """),
    ]

    static func text(_ name: String) -> String? { all.first { $0.name == name }?.text }
}
