import os
import QuartzCore
import SwiftUI
import UIKit

// Speed reporting (YUI-102, step 2 of YUI-98; spec yuigui/spec/PERF.md).
//
// Seven intervals on the hot paths (PERF.md section 2). Each starts at the
// person's action (or a delivery) and ends at the first display-link frame after
// the view that answers has committed: `end` waits for the next frame and takes
// its target time, the moment that frame goes on screen. Instruments sees each
// one as an OSSignposter interval by name; the app measures the same interval on
// the monotonic media clock and hands the number to PerfStore, off the main
// thread. On the main thread a sample costs a clock read and an array append.
//
// Numbers only: a sample is a name and milliseconds. Nothing a person wrote or
// an agent sent goes anywhere near this.

/// PERF.md section 2. The raw value is the row's `name` in yui_perf.
enum PerfInterval: String, CaseIterable, Sendable {
    case keystrokeRender = "keystroke_render"
    case sendBubble = "send_bubble"
    case arriveDrawn = "arrive_drawn"
    case swipe
    case fullscreenOpen = "fullscreen_open"
    case threadOpen = "thread_open"
    case threadOpenCold = "thread_open_cold"
    case launch
    case resume
    /// A finger lifts on a tap, to the first frame after the app handled it (YUI-101).
    case tap
    /// Not a time: hitch ms per second while the thread scrolls (YUI-101). Under 5 is smooth.
    case scrollHitch = "scroll_hitch"

    /// The signpost name Instruments shows.
    var signpost: StaticString {
        switch self {
        case .keystrokeRender: "keystroke_render"
        case .sendBubble: "send_bubble"
        case .arriveDrawn: "arrive_drawn"
        case .swipe: "swipe"
        case .fullscreenOpen: "fullscreen_open"
        case .threadOpen: "thread_open"
        case .threadOpenCold: "thread_open_cold"
        case .launch: "launch"
        case .resume: "resume"
        case .tap: "tap"
        case .scrollHitch: "scroll_hitch"
        }
    }
}

@MainActor
final class Perf {
    static let shared = Perf()

    private let signposter = OSSignposter(subsystem: "com.yuigui.app", category: .pointsOfInterest)
    private var open: [PerfInterval: (start: CFTimeInterval, state: OSSignpostIntervalState)] = [:]
    /// Ended, waiting for the next frame.
    private var ending: [(i: PerfInterval, start: CFTimeInterval, ended: CFTimeInterval, state: OSSignpostIntervalState)] = []
    private var link: CADisplayLink?
    /// The first thread shown since launch ends `launch` and is `thread_open_cold`.
    private(set) var launched = false
    private var coldPending = true

    /// The Speed switch (Dev builds only): console log and the overlay.
    var verbose: Bool { PerfSettings.speedOn }
    /// For the overlay: the newest keystroke and the frame rate.
    let live = PerfLive()

    private init() {}

    /// Starts `i` now (or at `at`, a media-clock time). A second begin restarts it.
    func begin(_ i: PerfInterval, at: CFTimeInterval = CACurrentMediaTime()) {
        if let old = open[i] { signposter.endInterval(i.signpost, old.state) }
        open[i] = (at, signposter.beginInterval(i.signpost))
    }

    /// Ends `i` on the first frame after this point. Nothing open: nothing.
    func end(_ i: PerfInterval) {
        guard let o = open.removeValue(forKey: i) else { return }
        ending.append((i, o.start, CACurrentMediaTime(), o.state))
        waitForFrame()
    }

    /// Begin and end in one: the change that answers is already made.
    func span(_ i: PerfInterval, from: CFTimeInterval = CACurrentMediaTime()) {
        begin(i, at: from)
        end(i)
    }

    func cancel(_ i: PerfInterval) {
        if let o = open.removeValue(forKey: i) { signposter.endInterval(i.signpost, o.state) }
    }

    func isOpen(_ i: PerfInterval) -> Bool { open[i] != nil }

    /// A thread tap. The first one since launch is the cold open.
    func threadTapped() {
        begin(coldPending ? .threadOpenCold : .threadOpen)
    }

    /// The thread's newest messages are in. Ends the open thread tap, and the
    /// first time, launch too (the first frame of the last open thread).
    func threadShown() {
        if coldPending {
            coldPending = false
            if isOpen(.threadOpen) { open[.threadOpenCold] = open.removeValue(forKey: .threadOpen) }
            // The app opened straight onto its last thread: no tap, the cold open starts with the process.
            if !isOpen(.threadOpenCold) { begin(.threadOpenCold, at: Self.processStart) }
            end(.threadOpenCold)
        } else {
            end(.threadOpen)
        }
        if !launched {
            launched = true
            begin(.launch, at: Self.processStart)
            end(.launch)
        }
    }

    /// When the process started, on the media clock (sysctl start time, moved
    /// across from the wall clock once).
    static let processStart: CFTimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return CACurrentMediaTime() }
        let tv = info.kp_proc.p_starttime
        let started = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        let age = Date().timeIntervalSince1970 - started
        return CACurrentMediaTime() - max(0, age)
    }()

    // MARK: Frames

    private func waitForFrame() {
        guard link == nil else { return }
        lastFrame = 0
        let l = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    fileprivate func frame(_ l: CADisplayLink) {
        // The frame this callback prepares goes up at targetTimestamp. A callback that
        // ran late (its target already past when the change was made) can't carry that
        // change: wait for the next one.
        let shown = l.targetTimestamp
        let done = ending.filter { $0.ended <= shown }
        ending.removeAll { $0.ended <= shown }
        if live.watching { live.tick(l) } else if ending.isEmpty, scrolling == nil { l.invalidate(); link = nil }
        hitch(l)
        for e in done {
            signposter.endInterval(e.i.signpost, e.state)
            record(e.i, ms: max(0, (shown - e.start) * 1000))
        }
    }

    private func record(_ i: PerfInterval, ms: Double) {
        if i == .keystrokeRender { live.lastKeystroke = ms }
        if verbose { Self.log.debug("perf \(i.rawValue, privacy: .public) \(ms, format: .fixed(precision: 1), privacy: .public) ms") }
        Task.detached(priority: .utility) { await PerfStore.shared.add(i.rawValue, ms: ms) }
    }

    /// Speed on (YUI-101): a frame that came more than half a frame late is a
    /// hitch; the log gets how late, so a run can sum hitch ms per second.
    private var lastFrame: CFTimeInterval = 0
    private func hitch(_ l: CADisplayLink) {
        defer { lastFrame = l.timestamp }
        let each = l.targetTimestamp - l.timestamp
        guard lastFrame > 0, each > 0, l.timestamp - lastFrame < 1 else { return }
        let late = l.timestamp - lastFrame - each
        guard late > each / 2 else { return }
        scrolling?.late += late
        if verbose { Self.log.debug("perf hitch \(late * 1000, format: .fixed(precision: 1), privacy: .public) ms") }
    }

    /// The thread is scrolling: frames are watched until it rests, then the late
    /// time per second of scrolling is one `scroll_hitch` sample.
    private var scrolling: (since: CFTimeInterval, late: Double)?
    func scrollMoving(_ moving: Bool) {
        if moving {
            guard scrolling == nil else { return }
            scrolling = (CACurrentMediaTime(), 0)
            waitForFrame()
        } else if let s = scrolling {
            scrolling = nil
            let secs = CACurrentMediaTime() - s.since
            if secs > 0.25 { record(.scrollHitch, ms: s.late * 1000 / secs) }
        }
    }

    /// A finger lifted on a tap (TapClock): `tap` runs from the touch to the first
    /// frame after the app has handled it, so a slow body or a blocked main thread shows.
    func tapped(at: CFTimeInterval) {
        begin(.tap, at: at)
        DispatchQueue.main.async { Perf.shared.end(.tap) }
    }

    /// The overlay wants the frame rate: keep the link running while it is up.
    func watchFrames(_ on: Bool) {
        live.watching = on
        if on { waitForFrame() }
    }

    /// Speed on at launch: frames are watched from the start, for the hitch log.
    func watchIfVerbose() {
        if verbose { watchFrames(true) }
    }

    nonisolated static let log = Logger(subsystem: "com.yuigui.app", category: "perf")
}

/// CADisplayLink holds its target strongly; this keeps Perf out of that.
private final class FrameTarget: NSObject {
    weak var perf: Perf?
    init(_ perf: Perf) { self.perf = perf }
    @MainActor @objc func tick(_ l: CADisplayLink) {
        guard let perf else { l.invalidate(); return }
        perf.frame(l)
    }
}

/// What the Speed overlay shows (Dev builds only).
@MainActor @Observable
final class PerfLive {
    var lastKeystroke: Double?
    var fps: Int = 0
    @ObservationIgnored var watching = false
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var since: CFTimeInterval = 0

    func tick(_ l: CADisplayLink) {
        frames += 1
        if since == 0 { since = l.timestamp }
        if l.timestamp - since >= 1 {
            fps = Int((Double(frames) / (l.timestamp - since)).rounded())
            frames = 0
            since = l.timestamp
        }
    }
}

/// `-yuiBodyLog` (Xcode builds): a view logs each time its body runs (YUI-99), so a
/// test can count how often typing makes the chat re-evaluate. Off everywhere else.
enum BodyLog {
    #if DEBUG
    static let on = ProcessInfo.processInfo.arguments.contains("-yuiBodyLog")
    #else
    static let on = false
    #endif
    static func hit(_ name: String) {
        if on { Perf.log.debug("body \(name, privacy: .public)") }
    }
}

/// The Speed switch lives in Settings > About this build, on Dev builds only
/// (the Yui Dev bundle, or an Xcode run). TestFlight and App Store builds never
/// read it, so a stale default can't turn anything on there.
enum PerfSettings {
    static let key = "yuiSpeed"
    static var available: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        #endif
    }
    static var speedOn: Bool { available && UserDefaults.standard.bool(forKey: key) }
}

/// Dev builds with Speed on (PERF.md section 4): the last keystroke_render and
/// the frame rate, small, top right. Draws nothing anywhere else.
struct SpeedOverlay: View {
    @AppStorage(PerfSettings.key) private var on = false
    private let live = Perf.shared.live

    var body: some View {
        if PerfSettings.available, on {
            HStack(spacing: 6) {
                Text(live.lastKeystroke.map { "key \(Int($0.rounded())) ms" } ?? "key -")
                Text("\(live.fps) fps")
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            // Under the navigation bar, clear of the Settings button.
            .padding(.top, 58).padding(.trailing, 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { Perf.shared.watchFrames(true) }
            .onDisappear { Perf.shared.watchFrames(false) }
        }
    }
}

/// Every tap in the app, timed (YUI-101): a recognizer on the window that never
/// wins, never delays a touch and never cancels one. A finger that lifts close to
/// where it went down is a tap; `Perf.tapped` measures from the touch's own time.
final class TapClock: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private var start: CGPoint?

    static func attach(to window: UIWindow) {
        guard !(window.gestureRecognizers ?? []).contains(where: { $0 is TapClock }) else { return }
        let clock = TapClock(target: nil, action: nil)
        clock.cancelsTouchesInView = false
        clock.delaysTouchesBegan = false
        clock.delaysTouchesEnded = false
        clock.delegate = clock
        window.addGestureRecognizer(clock)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        start = touches.count == 1 ? touches.first?.location(in: view) : nil
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let start, let t = touches.first, hypot(t.location(in: view).x - start.x, t.location(in: view).y - start.y) < 10 {
            let at = t.timestamp
            MainActor.assumeIsolated { Perf.shared.tapped(at: at) }
        }
        start = nil
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        start = nil
        state = .failed
    }

    override func reset() { start = nil }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
