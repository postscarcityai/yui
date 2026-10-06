import SwiftUI
import WebKit

// The native motion player (spec/MOTION.md 2.3, YUI-MOTION). A film is written by the agent as scenes
// (JavaScript bodies, `(t, c, api)`), streamed one by one. This file owns the box they run in: a
// WKWebView on the bundled harness-stream.html with no network, no storage and one message handler.
// MotionView.swift draws it full bleed with native chrome.

/// One scene of a film: a name, seconds, and the body of `(t, c, api)`.
struct MotionSceneSpec: Equatable, Sendable {
    var name: String
    var dur: Double
    var code: String

    /// The JSON the harness takes in `window.yui.scene(...)`. JSON is a JS expression, so nothing is
    /// ever concatenated into script text.
    var json: String {
        let o: [String: Any] = ["name": name, "dur": dur, "code": code]
        guard let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}

/// A voice-over line: the `api.say` cues, in film time (YUI-310 speaks them).
struct MotionCue: Equatable, Sendable {
    var text: String
    var from: Double
    var to: Double
}

/// What the harness tells the app. One handler, these verbs.
enum MotionMessage: Equatable {
    case ready
    case firstFrame
    case stall
    case slow
    case ended
    case error(scene: String, message: String)
    case tap(id: String?)
    case time(t: Double, total: Double, paused: Bool)
    case timeline(total: Double, scenes: Int, ended: Bool)
    case cues(scene: String, cues: [MotionCue])

    init?(_ body: Any) {
        guard let d = body as? [String: Any], let m = d["motion"] as? String else { return nil }
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        switch m {
        case "ready": self = .ready
        case "first-frame": self = .firstFrame
        case "stall": self = .stall
        case "slow": self = .slow
        case "ended": self = .ended
        case "error": self = .error(scene: d["scene"] as? String ?? "", message: d["message"] as? String ?? "")
        case "tap": self = .tap(id: d["id"] as? String)
        case "time": self = .time(t: num("t") ?? 0, total: num("total") ?? 0, paused: d["paused"] as? Bool ?? false)
        case "timeline": self = .timeline(total: num("total") ?? 0, scenes: Int(num("scenes") ?? 0), ended: d["ended"] as? Bool ?? false)
        case "cues":
            let raw = d["cues"] as? [[String: Any]] ?? []
            let cues = raw.compactMap { q -> MotionCue? in
                guard let text = q["text"] as? String else { return nil }
                return MotionCue(text: text, from: (q["from"] as? NSNumber)?.doubleValue ?? 0, to: (q["to"] as? NSNumber)?.doubleValue ?? 0)
            }
            self = .cues(scene: d["scene"] as? String ?? "", cues: cues)
        default: return nil
        }
    }
}

enum MotionPhase: Equatable {
    case loading            // the harness is booting, or scene 1 has not landed
    case playing
    case paused
    case ended
    case failed(String)     // the watchdog fired: the caller shows its fallback
}

/// The watchdog (spec 2.3): no first frame in 3 s, an error, or frames over 50 ms for 2 s. The slow-frame
/// clock lives in the harness (it sees every frame); this holds the rest.
enum MotionWatchdog {
    static let firstFrameSeconds: Double = 3
    /// What a failure tells the agent: `[yui] n1 motion error=<reason>` (the line is built by the caller,
    /// which knows the node id).
    static func reason(for message: MotionMessage) -> String? {
        switch message {
        case .error(let scene, let message): return scene.isEmpty ? message : "\(scene): \(message)"
        case .slow: return "slow frames"
        default: return nil
        }
    }
    static let noFirstFrame = "no first frame in \(Int(firstFrameSeconds)) s"
}

/// Owns the web view and the film's state. The view is the controller's, so a film survives the
/// SwiftUI view being rebuilt.
@MainActor
final class MotionController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published private(set) var phase: MotionPhase = .loading
    @Published private(set) var time: Double = 0
    @Published private(set) var total: Double = 0
    @Published private(set) var cues: [MotionCue] = []
    @Published private(set) var sceneCount = 0
    @Published private(set) var firstFrameSeconds: Double?
    /// Set once the first frame is on screen.
    var hasFirstFrame: Bool { firstFrameSeconds != nil }

    /// A tap on an `api.hit` target (a quiz or pick turn). Plain taps are the chrome's.
    var onHit: ((String) -> Void)?
    /// The watchdog fired: the reason, for the `[yui] n1 motion error=...` note to the agent.
    var onFailure: ((String) -> Void)?
    var onEnded: (() -> Void)?
    var onChromeTap: (() -> Void)?

    let web: WKWebView
    private let ucc = WKUserContentController()
    private var ready = false
    private var pending: [String] = []
    private var born = Date()
    private var firstSceneAt: Date?
    private var watchdog: Task<Void, Never>?
    private var cuesByScene: [String: [MotionCue]] = [:]
    private var sceneOrder: [String] = []

    /// Everything the harness cannot reach: network, popups, frames, storage.
    static let blockAll = """
    [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","raw","svg-document","media","popup","ping","fetch"]},"action":{"type":"block"}}]
    """

    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController = ucc
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        ucc.add(WeakHandler(self), name: "yui")
        web.isOpaque = true
        web.backgroundColor = UIColor(red: 11 / 255, green: 8 / 255, blue: 19 / 255, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = self
        web.accessibilityElementsHidden = true
        start()
    }

    private func start() {
        born = Date()
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "yui-motion-block", encodedContentRuleList: Self.blockAll) { [weak self] list, _ in
            Task { @MainActor in
                guard let self else { return }
                if let list { self.ucc.add(list) }
                self.web.loadHTMLString(Self.harnessHTML, baseURL: nil)
            }
        }
    }

    static var harnessHTML: String {
        guard let url = Bundle.main.url(forResource: "harness-stream", withExtension: "html"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "<body style='background:#0b0813'>" }
        return s
    }

    // MARK: Film

    /// A scene landed. Scene 1 plays at once; the rest queue behind it.
    func addScene(_ s: MotionSceneSpec) {
        if firstSceneAt == nil {
            // Scene 1 is in: the first frame has 3 s. A slow model is not a broken player, so the
            // clock starts here, not at launch.
            firstSceneAt = Date()
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(MotionWatchdog.firstFrameSeconds))
                guard !Task.isCancelled, let self, !self.hasFirstFrame else { return }
                self.fail(MotionWatchdog.noFirstFrame)
            }
        }
        sceneCount += 1
        run("window.yui.scene(\(s.json))")
    }

    /// The agent has written the last scene.
    func end() { run("window.yui.end()") }

    func pause() { guard phase == .playing else { return }; phase = .paused; run("window.yui.pause(true)") }
    func resume() { guard phase == .paused else { return }; phase = .playing; run("window.yui.pause(false)") }
    func toggle() { phase == .paused ? resume() : pause() }
    func seek(_ t: Double) { time = min(max(t, 0), total); if phase == .ended { phase = .paused }; run("window.yui.seek(\(time))") }
    func replay() { time = 0; phase = .playing; run("window.yui.replay()") }
    /// Reduce Motion: the last frame, still. It follows the film as scenes land.
    func setStill(_ on: Bool) { run("window.yui.still(\(on ? "true" : "false"))") }

    /// The `say` cues in film order, as one line for VoiceOver.
    var spoken: String { cues.map(\.text).joined(separator: " ") }

    /// Stop everything: the player leaves the screen.
    func stop() {
        watchdog?.cancel()
        ucc.removeScriptMessageHandler(forName: "yui")
        web.stopLoading()
    }

    func fail(_ reason: String) {
        guard !isFailed else { return }
        phase = .failed(reason)
        watchdog?.cancel()
        run("window.yui.pause(true)")
        onFailure?(reason)
    }
    var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    private func run(_ js: String) {
        guard ready else { pending.append(js); return }
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: Harness -> app

    func handle(_ m: MotionMessage) {
        if let reason = MotionWatchdog.reason(for: m) {
            // A scene that throws is cut short and the film goes on (the harness keeps the timeline);
            // only an error before anything has drawn, or slow frames, take the film down.
            if case .slow = m { fail(reason) } else if !hasFirstFrame { fail(reason) }
            return
        }
        switch m {
        case .ready:
            ready = true
            let queued = pending; pending = []
            for js in queued { web.evaluateJavaScript(js, completionHandler: nil) }
        case .firstFrame:
            firstFrameSeconds = firstSceneAt.map { Date().timeIntervalSince($0) } ?? Date().timeIntervalSince(born)
            if phase == .loading { phase = .playing }
        case .stall: break
        case .ended:
            if phase == .playing || phase == .paused || phase == .loading { phase = .ended; onEnded?() }
        case .time(let t, let tot, _):
            time = t; total = tot
        case .timeline(let tot, _, _):
            total = tot
        case .cues(let scene, let new):
            if cuesByScene[scene] == nil { sceneOrder.append(scene) }
            cuesByScene[scene] = new
            cues = sceneOrder.flatMap { cuesByScene[$0] ?? [] }.sorted { $0.from < $1.from }
        case .tap(let id):
            if let id { onHit?(id) } else { onChromeTap?() }
        case .error, .slow: break
        }
    }

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = MotionMessage(message.body) else { return }
        MainActor.assumeIsolated { handle(m) }
    }

    /// Only the harness page ever loads. A link, a redirect or a frame goes nowhere.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let own = action.targetFrame?.isMainFrame == true && action.navigationType == .other
            && (action.request.url?.absoluteString ?? "about:blank") == "about:blank"
        return own ? .allow : .cancel
    }

    /// WKUserContentController keeps its handler strongly; this keeps the controller free to deinit.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: MotionController?
        init(_ t: MotionController) { target = t }
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(ucc, didReceive: message)
        }
    }
}

/// What the agent hears when the film fails (spec 2.3): the node id is the caller's.
enum MotionReport {
    static func line(node: String, reason: String) -> String {
        "[yui] \(node) motion error=\(reason.replacingOccurrences(of: "\n", with: " "))"
    }
}
