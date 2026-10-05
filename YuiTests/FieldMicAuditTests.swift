import XCTest

/// Voice first guard (t_6f00ece2): every text field in the app has a mic beside it, or sits on the
/// exempt list below with its reason. A new TextField, SecureField or TextEditor without either
/// fails here, naming file:line. A plain source scan, like the web check (site/lib/web/fieldmic-audit.mjs).
final class FieldMicAuditTests: XCTestCase {
    /// A mic beside the field: the shared mic in either spelling (FieldMic for a field of words, NameMic
    /// for a name or a search; one button, Chat/FieldMic.swift), the bar's own buttons, or the mic card itself.
    static let micMarkers = ["NameMic(", "FieldMic(", "MicPreset(", "BarButtons(", "SendOrMic("]
    /// Lines after the field where its mic must show up (the field's own row).
    static let window = 14

    /// Fields without a mic on purpose, named `File.swift#first argument`, each with the reason.
    static let exempt: [String: String] = [
        "ModelKeyForm.swift#\"Paste your key\"": "secret: an API key is never spoken",
        "ModelKeyForm.swift#\"Server address, https://...\"": "a server address, not words",
        "ModelKeyForm.swift#\"Model name\"": "a model id, not words",
        "SettingsView.swift#\"Paste your Firecrawl key\"": "secret: a search key is never spoken",
        "VaultViews.swift#\"Paste your key\"": "secret: a vault key is never spoken",
        "VaultViews.swift#\"Name\"": "key vault form: no mic anywhere on the vault pages",
        "VaultViews.swift#\"10\"": "a spend cap number, not words",
        "SignInView.swift#\"ABCDE-FGHJK\"": "a pairing code, not words",
        "SignInView.swift#\"Code\"": "a sign in code, not words",
        "ControlsViews.swift#text: $text": "code editor",
        "ControlsViews.swift#\"m h dom mon dow\"": "cron expression",
        "Composer.swift#prompt": "the composer: the bar's own mic and hands free are the voice way in",
        "GroupBar.swift#photos.isEmpty ? \"Message the group\" : \"Add a caption\"": "the group composer: the bar's own mic (BarButtons showMic)",
        "MicPreset.swift#\"Or type it here\"": "the typing fallback inside the mic card, which is the mic",
        "FormPreset.swift#field.label": "form fields are filled by the card's mic and the page mic (VoiceFill, PageVoice)",
    ]

    struct Field { let file: String; let line: Int; let key: String; let covered: Bool }

    static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Yui/Sources")
    }

    /// The first argument of the field call: a string literal, else the text up to the first comma.
    static func firstArgument(_ line: String, after kind: Range<String.Index>) -> String {
        var rest = line[kind.upperBound...].drop(while: { $0 == "(" })
        if rest.first == "\"", let end = rest.dropFirst().firstIndex(of: "\"") {
            rest = rest[rest.startIndex...end]
            return String(rest)
        }
        // A ternary with literals ("photos.isEmpty ? \"a\" : \"b\"") stops at the comma that ends the first argument.
        let arg = rest.prefix(while: { $0 != "," && $0 != ")" })
        return arg.trimmingCharacters(in: .whitespaces)
    }

    static func scan(_ dir: URL = sources) throws -> [Field] {
        var out: [Field] = []
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        for url in files {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            let hits = lines.indices.compactMap { i -> (Int, String)? in
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return nil }
                for kind in ["SecureField(", "TextField(", "TextEditor("] {
                    if let r = l.range(of: kind) {
                        let before = l[..<r.lowerBound]
                        if let c = before.last, c.isLetter || c.isNumber { continue }   // MyTextField(
                        return (i, firstArgument(l, after: r))
                    }
                }
                return nil
            }
            for (n, (i, arg)) in hits.enumerated() {
                // The mic is in this field's row: before the next field, within the window.
                let stop = min(lines.count - 1, i + window, (n + 1 < hits.count ? hits[n + 1].0 - 1 : .max))
                let covered = i <= stop && lines[i...stop].contains { l in micMarkers.contains { l.contains($0) } }
                out.append(Field(file: url.lastPathComponent, line: i + 1, key: "\(url.lastPathComponent)#\(arg)", covered: covered))
            }
        }
        return out
    }

    func testEveryTextFieldHasAMicOrAReason() throws {
        let fields = try Self.scan()
        XCTAssertGreaterThan(fields.count, 20, "the scan found no fields: is \(Self.sources.path) the source folder?")
        for f in fields where !f.covered && Self.exempt[f.key] == nil {
            XCTFail("\(f.file):\(f.line) has a text field with no mic beside it. Add a FieldMic (or a NameMic for a name), or exempt \(f.key) with a reason.",
                    file: #filePath, line: 1)
        }
    }

    func testExemptListHasNoStaleOrPointlessEntries() throws {
        let fields = try Self.scan()
        let keys = Set(fields.map(\.key))
        for (key, reason) in Self.exempt {
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) has no reason")
            XCTAssertTrue(keys.contains(key), "\(key) is exempt but no such field exists any more: remove it")
            if let f = fields.first(where: { $0.key == key }), f.covered {
                XCTFail("\(key) now has a mic: take it off the exempt list")
            }
        }
    }
}
