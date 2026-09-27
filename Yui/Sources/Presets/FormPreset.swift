import PhotosUI
import SwiftUI
import YuiLines

extension EnvironmentValues {
    /// Inside a plan or the stage's questions, where the host has the one Send
    /// (YUI-156, feedback AOTM4UtV: "I don't see a reason to have a send button
    /// on about you section"). A hosted form draws no Submit of its own.
    @Entry var ylHostedSubmit = false
}

/// `form`: one card of typed fields, sent as `{form: {key: value}}` on submit.
/// Hosted by a plan or the stage it is just fields: every edit hands the host
/// `{form: {...}}` once the person has set any field (nothing while all are empty),
/// plus `missing: true` while a required field is empty, so the host's Send
/// carries it and waits for it.
struct FormPreset: View {
    let c: YLComponent
    @State private var values: [String: YLValue] = [:]
    @State private var sent = false
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ylEmit) private var emit
    @Environment(\.ylHostedSubmit) private var hosted

    private var fields: [FormField] { (c.props["fields"]?.array ?? []).compactMap(FormField.init) }

    var body: some View {
        let s = theme.swatch(scheme)
        let fields = fields
        let ready = fields.allSatisfy { !$0.required || filled($0) }
        PresetCard {
            if let t = c.string("title") { PresetTitle(text: t) }
            ForEach(fields) { f in
                FieldRow(field: f, value: Binding(get: { values[f.key] ?? f.initial }, set: { values[f.key] = $0 }))
            }
            if !hosted {
                OptionPill(text: sent ? "Sent" : c.string("submit") ?? "Submit", fill: s.accent, ink: s.onAccent, on: ready && !sent,
                           grow: true) {
                    sent = true
                    emit(event(fields))
                }
                .disabled(!ready)
            }
        }
        .disabled(sent)
        // Reopened thread: a sent form comes back filled in and sent. Hosted,
        // its answer is inside the plan's.
        .onChange(of: answers(scope, c.ylID), initial: true) { _, v in
            guard !sent, !hosted, let form = v?["form"]?.object else { return }
            restore(form, fields)
            sent = true
        }
        .onAppear {
            guard hosted, values.isEmpty, let g = c.inGroup,
                  let form = answers(scope, g)?["plan"]?[c.ylID]?.object else { return }
            restore(form, fields)
        }
        // No debounce: a Send right after the last key must carry it.
        .onChange(of: values, initial: true) {
            guard hosted else { return }
            // A date or a slider starts with a value; only what the person set counts.
            let any = fields.contains { values[$0.key] != nil && filled($0) }
            var e = any ? event(fields) : c.event([:])
            if !ready { e.value["missing"] = .bool(true) }
            emit(e)
        }
    }

    /// The whole form as its answer, `{form: {key: value}}`, echoed as "Label: value" lines.
    private func event(_ fields: [FormField]) -> YLEvent {
        var out: [String: YLValue] = [:]
        for f in fields {
            let v = values[f.key] ?? f.initial
            out[f.key] = f.type == "number" ? v.string.flatMap(Double.init).map(YLValue.number) ?? v : v
        }
        let echo = fields.compactMap { f -> String? in
            guard let v = out[f.key], let t = f.type == "photo" && v != .null ? "added" : FieldRow.display(v),
                  !t.isEmpty else { return nil }
            return "\(f.label): \(t)"
        }.joined(separator: "\n")
        return c.event(["form": .object(out)], echo: echo.isEmpty ? "Sent" : echo)
    }

    /// Number fields edit as text; they went out as numbers.
    private func restore(_ form: [String: YLValue], _ fields: [FormField]) {
        for f in fields { if let v = form[f.key] { values[f.key] = f.type == "number" ? v.number.map { .string(YLComponent.format($0)) } ?? v : v } }
    }

    private func filled(_ f: FormField) -> Bool {
        switch values[f.key] ?? f.initial {
        case .string(let s): !s.trimmingCharacters(in: .whitespaces).isEmpty
        case .null: false
        default: true
        }
    }
}

struct FormField: Identifiable {
    let key: String
    let label: String
    let type: String
    let required: Bool
    let options: [String]
    let min: Double
    let max: Double
    var id: String { key }

    init?(_ v: YLValue) {
        guard let key = v["key"]?.string else { return nil }
        self.key = key
        let l = v["label"]?.string ?? key.replacingOccurrences(of: "_", with: " ")
        label = l.prefix(1).uppercased() + l.dropFirst()
        type = v["type"]?.string ?? "text"
        required = v["required"]?.bool ?? false
        options = v["options"]?.array?.compactMap(\.string) ?? []
        min = v["min"]?.number ?? 1
        max = Swift.max(v["max"]?.number ?? 5, min)
    }

    /// What a field holds before the user touches it. Text-like fields start empty.
    var initial: YLValue {
        switch type {
        case "yes": .bool(false)
        case "range": .number(((min + max) / 2).rounded())
        case "date": .string(Self.day.string(from: .now))
        case "time": .string(Self.clock.string(from: .now))
        case "choice", "photo": .null
        default: .string("")
        }
    }

    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
}

private struct FieldRow: View {
    let field: FormField
    @Binding var value: YLValue
    @State private var photo: PhotosPickerItem?
    @State private var uploading = false
    @Environment(\.yuiMedia) private var media
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            if field.type != "yes" {
                HStack(spacing: 2) {
                    Text(field.label)
                    if field.required { Text("*").foregroundStyle(s.accent) }
                }
                .font(theme.font(theme.type.caption, .bold))
                .foregroundStyle(s.inkSoft)
            }
            input(s)
        }
    }

    @ViewBuilder
    private func input(_ s: Swatch) -> some View {
        switch field.type {
        case "yes":
            Toggle(isOn: Binding(get: { value.bool ?? false }, set: { value = .bool($0) })) {
                Text(field.label).font(theme.font(theme.type.body, .semibold)).foregroundStyle(s.ink)
            }
            .tint(s.mint)
        case "range":
            let n = value.number ?? field.min
            HStack(spacing: theme.spacing.m) {
                Slider(value: Binding(get: { n }, set: { value = .number($0.rounded()) }), in: field.min...field.max, step: 1)
                    .tint(s.accent)
                Text(YLComponent.format(n))
                    .font(theme.font(theme.type.title, .heavy).monospacedDigit())
                    .foregroundStyle(s.ink)
                    .frame(minWidth: 32)
            }
        case "choice":
            FlowLayout(spacing: theme.spacing.s) {
                ForEach(Array(field.options.enumerated()), id: \.offset) { i, o in
                    OptionPill(text: o, fill: s.candy[i % 4], ink: s.candyInk(i), on: value.string == o) {
                        withAnimation(theme.spring) { value = .string(o) }
                    }
                }
            }
        case "date", "time":
            let isDate = field.type == "date"
            let f = isDate ? FormField.day : FormField.clock
            DatePicker(field.label, selection: Binding(get: { value.string.flatMap(f.date(from:)) ?? .now },
                                                      set: { value = .string(f.string(from: $0)) }),
                       displayedComponents: isDate ? .date : .hourAndMinute)
                .labelsHidden()
                .tint(s.accent)
        case "photo":
            PhotosPicker(selection: $photo, matching: .images) {
                Label(uploading ? "Adding your photo" : value == .null ? "Add a photo" : "Photo added",
                      systemImage: uploading ? "arrow.up.circle" : value == .null ? "camera.fill" : "checkmark")
                    .font(theme.font(theme.type.body, .bold))
                    .foregroundStyle(s.userInk)
                    .padding(.horizontal, theme.spacing.l)
                    .padding(.vertical, theme.spacing.m)
                    .background(value == .null ? s.lavender : s.mint, in: Capsule())
            }
            .disabled(uploading)
            // The photo goes up to yui-media first; the answer is its path, which the agent's host downloads.
            .onChange(of: photo) { _, item in
                guard let item else { value = .null; return }
                uploading = true
                Task {
                    defer { uploading = false }
                    guard let media, let data = try? await item.loadTransferable(type: Data.self),
                          let path = try? await media.upload(photo: data) else { value = .null; photo = nil; return }
                    value = .string(path)
                }
            }
        default:
            textInput(s)
        }
    }

    private func textInput(_ s: Swatch) -> some View {
        let text = Binding(get: { value.string ?? "" }, set: { value = .string($0) })
        let long = field.type == "long" || field.type == "voice"
        return HStack(spacing: theme.spacing.s) {
            Group {
                if long {
                    TextField(field.label, text: text, axis: .vertical).lineLimit(3...6)
                } else {
                    TextField(field.label, text: text)
                }
            }
            .font(theme.font(theme.type.body))
            .foregroundStyle(s.ink)
            .keyboardType(keyboard)
            .textContentType(content)
            .textInputAutocapitalization(["email", "url"].contains(field.type) ? .never : .sentences)
            if field.type == "voice" {
                // The keyboard's dictation key does speech to text until the `mic` preset lands.
                Image(systemName: "mic.fill")
                    .foregroundStyle(s.userInk)
                    .frame(width: 34, height: 34)
                    .background(s.accent, in: Circle())
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.vertical, theme.spacing.m)
        .background(s.background, in: .rect(cornerRadius: long ? theme.radius.bubble : theme.radius.pill))
        .overlay(RoundedRectangle(cornerRadius: long ? theme.radius.bubble : theme.radius.pill).stroke(s.outline, lineWidth: 1.5))
    }

    private var keyboard: UIKeyboardType {
        switch field.type {
        case "number": .decimalPad
        case "email": .emailAddress
        case "phone": .phonePad
        case "url": .URL
        default: .default
        }
    }

    private var content: UITextContentType? {
        switch field.type {
        case "email": .emailAddress
        case "phone": .telephoneNumber
        case "url": .URL
        default: nil
        }
    }

    static func display(_ v: YLValue) -> String? {
        switch v {
        case .string(let s): s
        case .number(let n): YLComponent.format(n)
        case .bool(let b): b ? "yes" : "no"
        default: nil
        }
    }
}
