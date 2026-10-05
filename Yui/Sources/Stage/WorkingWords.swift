import Foundation

/// The words on the working screen (Chris, TestFlight ADv4muh06N4PD2IA1sV2Fhc: "Running a command
/// is so ominous", "just summarize what I asked in 5 to 12 words").
///
/// Two small pure helpers, no host change. The doing words the host sends stay the plain, stable
/// ones (the blob's shape reads them, see StageAction), so the friendlier voice is applied only
/// where they are shown.
enum WorkingWords {
    /// What the app shows for each plain doing the host sends for a tool call. Anything else (the
    /// agent's own `doing` words, a custom line) is shown as it came.
    static let voice: [String: String] = [
        "Running a command": "Tinkering away",
        "Running some code": "Trying something out",
        "Searching the web": "Looking around the web",
        "Reading a web page": "Skimming a page",
        "Reading a file": "Reading up on it",
        "Looking through files": "Digging through files",
        "Writing it down": "Jotting it down",
        "Making an edit": "Making a tweak",
        "Checking on a job": "Peeking at progress",
        "Checking my notes": "Flipping through my notes",
        "Looking back at our chats": "Remembering our chats",
        "Checking how to do this": "Checking the playbook",
        "Updating what I know": "Learning a new trick",
        "Handing part of this to a helper": "Calling in a helper",
        "Planning the steps": "Mapping the steps",
        "Looking at the picture": "Studying the picture",
        "Making an image": "Painting something",
        "Recording audio": "Warming up my voice",
        "Setting up a schedule": "Setting a reminder",
        "Sending a message": "Passing a note",
        "Drafting a change": "Sketching a change",
        "Using the browser": "Browsing around",
        "Checking the board": "Checking the board",
        "Using a connected app": "Reaching a connected app",
        "Checking your home": "Checking on the house",
    ]

    /// The words to show for a doing text.
    static func friendly(_ text: String) -> String { voice[text] ?? text }

    /// Words that open a message without saying anything.
    private static let lead: [String] = [
        "no, i'm just saying that", "no i'm just saying that", "i'm just saying that", "i was just saying that",
        "hey yui,", "hey yui", "hi yui,", "hi yui", "ok so", "okay so", "so", "ok,", "okay,", "ok", "okay",
        "no,", "no", "yeah,", "yeah", "um,", "um", "uh,", "uh", "well,", "well", "and", "but",
        "can you please", "could you please", "can you", "could you", "would you", "will you",
        "please", "i wanna call your attention that", "i want to call your attention that",
        "i'd like you to", "i want you to", "i need you to", "i was wondering if you could",
        "i'm wondering if", "i wonder if",
    ]

    private static let dangling: Set<String> = ["and", "i", "the", "a", "an", "to", "of", "that", "but", "or", "so", "if",
                                                "you", "we", "it", "is", "in", "on", "my", "your", "for", "with", "i'm", "wanna"]

    /// The ask in at most `limit` words, a cheap local trim: the first sentence, filler lead-ins
    /// off, the rest cut at a word with an ellipsis. Under four words it is left as said.
    static func gist(_ ask: String, limit: Int = 12) -> String {
        var s = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        // The first sentence says it; a later one is the detail.
        if let end = s.firstIndex(where: { ".?!\n".contains($0) }), s.distance(from: s.startIndex, to: end) >= 12 {
            s = String(s[...end])
        }
        // Peel lead-ins off, longest first, until none matches.
        var peeled = true
        while peeled {
            peeled = false
            let low = s.lowercased()
            for l in lead.sorted(by: { $0.count > $1.count }) where low.hasPrefix(l) {
                let rest = s.dropFirst(l.count)
                if let f = rest.first, f.isLetter || f.isNumber { continue }
                let trimmed = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-").union(.whitespacesAndNewlines))
                if trimmed.split(separator: " ").count >= 3 { s = trimmed; peeled = true }
                break
            }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".!,;: ").union(.whitespacesAndNewlines))
        let words = s.split(whereSeparator: \.isWhitespace)
        guard words.count > limit else { return s.prefix(1).uppercased() + s.dropFirst() }
        var kept = Array(words.prefix(limit))
        // Never end on a hanging word ("... December 25 and I").
        while kept.count > 4, let last = kept.last?.lowercased().trimmingCharacters(in: .punctuationCharacters), dangling.contains(last) {
            kept.removeLast()
        }
        let cut = kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,;:-"))
        return cut.prefix(1).uppercased() + cut.dropFirst() + "…"
    }
}
