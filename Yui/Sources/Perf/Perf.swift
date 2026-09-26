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
        if live.watching { live.tick(l) } else if ending.isEmpty { l.invalidate(); link = nil }
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

    /// The overlay wants the frame rate: keep the link running while it is up.
    func watchFrames(_ on: Bool) {
        live.watching = on
        if on { waitForFrame() }
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
