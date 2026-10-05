import MetalKit
import SwiftUI
import YuiSound

// The visual behind the stage (YUI-124 step 2, spec yuigui/spec/VISUAL.md): the
// shaders in Visual.metal, drawn by one MTKView at the plan's budget. Half
// resolution (grain three quarters), 60 fps alone, 30 behind words or when the
// phone is warm, one still frame under Reduce Motion, Low Power, heat or in the
// background, and nothing at all once the stage closes (the view goes away).
// The sound comes from VisualSound (YUI-125), read at 30 Hz: a level and three
// bands from the mic, the agent's voice or the music tools, as `react=` says.
// Each goes through the look's envelope; the shader says what it does with them.

/// Low Power Mode and the phone's heat, as the visual needs them.
@Observable @MainActor
final class VisualConditions {
    static let shared = VisualConditions()
    private(set) var lowPower: Bool
    private(set) var thermal: ProcessInfo.ThermalState

    private init() {
        let info = ProcessInfo.processInfo
        #if DEBUG
        // -yuiLowPower: screenshots and tests of the still.
        lowPower = info.isLowPowerModeEnabled || info.arguments.contains("-yuiLowPower")
        #else
        lowPower = info.isLowPowerModeEnabled
        #endif
        thermal = info.thermalState
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VisualConditions.shared.update() }
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VisualConditions.shared.update() }
        }
    }

    private func update() {
        let info = ProcessInfo.processInfo
        #if DEBUG
        lowPower = info.isLowPowerModeEnabled || info.arguments.contains("-yuiLowPower")
        #else
        lowPower = info.isLowPowerModeEnabled
        #endif
        thermal = info.thermalState
    }
}

struct StageVisual: View {
    let plan: VisualPlan
    /// The raw sound, read at the meter's rate. Nil: what `plan.react` names, from VisualSound.
    var meter: (() -> LevelMeter.Reading)?

    /// Opens the room mic while a `react=mic` visual moves on screen.
    private var room: Bool { plan.react == "mic" && !plan.still }

    var body: some View {
        let react = plan.react
        VisualMetalView(plan: plan, meter: meter ?? Self.demoMeter ?? { VisualSound.shared.reading(react) })
            .onAppear { VisualSound.shared.watch(true) }
            .onDisappear { VisualSound.shared.watch(false) }
            .task(id: room) {
                guard room else { return }
                VisualSound.shared.listenToRoom(true)
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
                VisualSound.shared.listenToRoom(false)
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(plan.label)
            .accessibilityHint(plan.hint ?? "")
            .accessibilityValue(plan.still ? "Still" : "\(plan.fps) fps")
            .accessibilityIdentifier("stage-visual")
            .overlay(alignment: .topLeading) { if VisualFrames.enabled { VisualFramesProbe() } }
    }

    /// DEBUG `-yuiVisualLevel 0.6`: a steady level, for screenshots of a look swelling.
    static var demoMeter: (() -> LevelMeter.Reading)? {
        #if DEBUG
        let v = UserDefaults.standard.double(forKey: "yuiVisualLevel")
        return v > 0 ? { .flat(v) } : nil
        #else
        return nil
        #endif
    }
}

/// The orb's place as the layout has it. The slot on show writes its frame here and only the
/// visual's host reads it, so a slot that moves under a finger (the pager, the pull home) re-runs
/// the visual and nothing else.
@Observable @MainActor
final class OrbSpot {
    /// The slot's frame in global points. Nil: no layout keeps a place for the orb right now.
    private(set) var frame: CGRect?
    @ObservationIgnored private var owner: UUID?

    func claim(_ id: UUID, _ frame: CGRect) {
        owner = id
        if self.frame != frame { self.frame = frame }
    }

    /// The slot left. A newer slot that already claimed the place keeps it.
    func release(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        frame = nil
    }
}

extension EnvironmentValues {
    /// Set by the stage: where an `OrbSlot` reports its frame.
    @Entry var orbSpot: OrbSpot? = nil
}

/// Room for the orb in a layout (YUI-232, "the shader draws the agent"): the home keeps one over
/// the agent's name, the working state a big one over what it is doing. It draws nothing itself;
/// the shader behind the stage draws the orb exactly here.
struct OrbSlot: View {
    var size: CGFloat
    @Environment(\.orbSpot) private var spot
    @State private var id = UUID()

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { spot?.claim(id, $0) }
            .onDisappear { spot?.release(id) }
            .accessibilityHidden(true)
    }
}

/// The visual with the orb in its place. `up`: the orb has the stage (the home, the working state,
/// the mic). With a page of words or a screen up it is false, and the orb tucks away.
struct StageVisualHost: View {
    let plan: VisualPlan
    let spot: OrbSpot
    let up: Bool
    @State private var bounds = CGRect.zero

    var body: some View {
        StageVisual(plan: placed)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { bounds = $0 }
    }

    private var placed: VisualPlan {
        var p = plan
        guard p.isOrb else { return p }
        if up, let f = spot.frame, bounds.width > 0, bounds.height > 0 {
            p.spot = .init(x: (f.midX - bounds.minX) / bounds.width, y: (f.midY - bounds.minY) / bounds.height,
                           r: min(f.width, f.height) / 2 / bounds.height, presence: 1)
        } else {
            p.spot = .away
        }
        return p
    }
}

/// Frames per second, measured (DEBUG `-yuiVisualMeter`, proof for the budget): what the
/// visual drew, and what the app's own display link got, so a visual that costs the
/// app its 60 (120 on ProMotion) shows up as a drop in `app`.
@MainActor
final class VisualFrames: NSObject {
    static let shared = VisualFrames()
    static var enabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-yuiVisualMeter")
        #else
        false
        #endif
    }
    private(set) var visual = 0
    private(set) var app = 0
    private(set) var drawn = 0
    private var link: CADisplayLink?
    private var ticks = 0, draws = 0
    private var since: CFTimeInterval = 0

    func start() {
        guard Self.enabled, link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func drew() { draws += 1; drawn += 1 }

    @objc private func tick(_ l: CADisplayLink) {
        ticks += 1
        if since == 0 { since = l.timestamp; ticks = 0; draws = 0; return }
        let dt = l.timestamp - since
        guard dt >= 1 else { return }
        app = Int((Double(ticks) / dt).rounded())
        visual = Int((Double(draws) / dt).rounded())
        peak = peakNow; peakNow = 0
        ticks = 0; draws = 0; since = l.timestamp
    }

    /// The level the shader got last, after the envelope, and the loudest in the last second (YUI-125).
    var level = 0.0
    private(set) var peak = 0.0
    private var peakNow = 0.0

    func heard(_ l: Double) { level = l; peakNow = max(peakNow, l) }

    var words: String { "visual \(visual) fps, app \(app) fps, level \(String(format: "%.2f", peak)), \(drawn) frames" }
}

/// The measured numbers as an invisible element UI tests read (`stage-visual-fps`).
private struct VisualFramesProbe: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Visual frames")
                .accessibilityValue(VisualFrames.shared.words)
                .accessibilityIdentifier("stage-visual-fps")
        }
        .onAppear { VisualFrames.shared.start() }
    }
}

private struct VisualMetalView: UIViewRepresentable {
    let plan: VisualPlan
    let meter: (() -> LevelMeter.Reading)?

    func makeCoordinator() -> VisualRenderer { VisualRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = true
        view.backgroundColor = .clear
        view.autoResizeDrawable = true
        // One small drawable in flight at a time is plenty for a backdrop.
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.meter = meter
        context.coordinator.apply(plan, to: view)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: VisualRenderer) {
        view.isPaused = true
        view.delegate = nil
    }
}

/// The uniforms, laid out like Visual.metal's VisualUniforms (float3 is 16 bytes there and here).
private struct VisualUniforms {
    var res: SIMD2<Float>
    var time: Float
    var level: Float
    var dim: Float
    var scrim: Float
    var zone: SIMD2<Float>
    var a, b, c, ground: SIMD3<Float>
    /// Lows, mids, highs after the envelope (YUI-125).
    var bands: SIMD3<Float>
    /// The blob's state weights (YUI-232): thinking, reading, running, searching; then talking, done, since.
    var act: SIMD4<Float>
    var act2: SIMD4<Float>
    /// The orb's place as drawn: center x and y (fractions of the view from its top left), radius (a
    /// fraction of the height), presence.
    var orb: SIMD4<Float>
}

@MainActor
final class VisualRenderer: NSObject, MTKViewDelegate {
    /// One device, queue, library and pipeline cache for every renderer: a thread's stage
    /// makes a new renderer each time it opens, and each one compiling its own is the growth
    /// the 0.6.0 memory run caught once every agent had a default visual.
    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    private static let library = device?.makeDefaultLibrary()
    private static var pipelines: [String: MTLRenderPipelineState] = [:]
    var device: MTLDevice? { Self.device }
    private var queue: MTLCommandQueue? { Self.queue }
    private var library: MTLLibrary? { Self.library }
    private var plan: VisualPlan?
    var meter: (() -> LevelMeter.Reading)?

    /// The clock (already at the look's pace), the sound after the envelope, the raw sound and when it was read.
    private var clock = 0.0
    private var heard = LevelMeter.Reading.zero
    private var raw = LevelMeter.Reading.zero
    private var lastFrame: CFTimeInterval = 0
    private var lastMeter: CFTimeInterval = 0
    /// The blob's shape (YUI-232): each state's weight, eased toward the plan's action so the
    /// shapes morph (action.mjs easeWeights), and seconds since the action changed (done's ring).
    private var weights = BlobWeights()
    private var since = 9.0
    /// The orb as drawn (x, y, radius, presence), eased toward the plan's spot so it glides between
    /// its places and never jumps, and the radius it last had a place for.
    private var orb = OrbPlace()
    /// Tucked away with nothing left to move: the frame on screen is the last one until the plan changes.
    private var resting = false

    func attach(_ view: MTKView) {
        view.enableSetNeedsDisplay = true
        view.isPaused = true
    }

    func apply(_ plan: VisualPlan, to view: MTKView) {
        let old = self.plan
        self.plan = plan
        let screen = view.window?.screen.scale ?? view.traitCollection.displayScale
        let scale = max(1, screen) * plan.scale
        if view.contentScaleFactor != scale { view.contentScaleFactor = scale }
        if plan.still {
            // One still frame, then nothing until something changes.
            clock = 8
            heard = .zero
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            if old != plan { view.setNeedsDisplay() }
        } else if resting, old != plan, plan.spot?.presence ?? 1 == 0 {
            // Still tucked away, but something it draws with changed (a theme, the size): one more frame.
            view.setNeedsDisplay()
        } else if !resting || old != plan {
            // A quiet default starts at its idle rate; render() lifts it while something is heard.
            if old == nil || old?.fps != plan.fps || old?.idleFps != plan.idleFps || old?.still == true {
                view.preferredFramesPerSecond = plan.idleFps
            }
            resting = false
            view.enableSetNeedsDisplay = false
            if view.isPaused { lastFrame = 0; view.isPaused = false }
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { if plan?.still == true || resting { view.setNeedsDisplay() } }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    private func render(_ view: MTKView) {
        guard let plan, let queue, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let pipeline = pipeline(plan.look, format: view.colorPixelFormat) else { return }
        let now = CACurrentMediaTime()
        if weights.action != plan.action { weights.action = plan.action; since = 0 }
        if plan.still { weights = BlobWeights(plan.action); since = 9 }
        let size = view.drawableSize
        let goal = orb.goal(plan.spot, aspect: size.height > 0 ? size.width / size.height : 0.46)
        // The orb follows the voice softly, whatever the agent's pulse: it swells, it never jitters.
        let env = plan.isOrb ? plan.env.softened : plan.env
        if plan.still {
            orb.snap(to: goal)
        } else {
            let dt = lastFrame == 0 ? 0 : min(now - lastFrame, 0.1)
            lastFrame = now
            clock += dt * plan.speed
            if now - lastMeter >= 1 / VisualPlan.Budget.meterHz {
                raw = meter?() ?? .zero
                lastMeter = now
            }
            let ms = dt * 1000
            heard = .init(level: env.follow(heard.level, raw.level, dt: ms), low: env.follow(heard.low, raw.low, dt: ms),
                          mid: env.follow(heard.mid, raw.mid, dt: ms), high: env.follow(heard.high, raw.high, dt: ms))
            weights.ease(toward: plan.action, dt: dt)
            since += dt
            orb.ease(toward: goal, dt: dt)
            // A shape on the move draws at the full rate even when nothing is heard.
            let silent = max(heard.level, heard.low, heard.mid, heard.high) < 0.02 && weights.settled(plan.action == .idle)
                && orb.settled(goal)
            let want = silent ? plan.idleFps : plan.fps
            if view.preferredFramesPerSecond != want { view.preferredFramesPerSecond = want }
            // Tucked away behind words: what is left (the wash) does not move, so this is the last
            // frame until the plan changes. A page of words costs the phone nothing.
            if plan.isOrb, goal.presence == 0, orb.away {
                resting = true
                view.isPaused = true
                view.enableSetNeedsDisplay = true
            }
        }
        count(now)

        var u = VisualUniforms(
            res: SIMD2(Float(size.width), Float(size.height)), time: Float(clock), level: Float(env.shown(heard.level)),
            dim: Float(plan.dim), scrim: Float(plan.scrim),
            zone: SIMD2(Float(plan.zone.low), Float(plan.zone.high)),
            a: Self.vec(plan.colors.a), b: Self.vec(plan.colors.b), c: Self.vec(plan.colors.c), ground: Self.vec(plan.colors.ground),
            bands: SIMD3(Float(env.shown(heard.low)), Float(env.shown(heard.mid)), Float(env.shown(heard.high))),
            act: SIMD4(Float(weights[.thinking]), Float(weights[.reading]), Float(weights[.running]), Float(weights[.searching])),
            act2: SIMD4(Float(weights[.talking]), Float(weights[.done]), Float(since), 0),
            orb: SIMD4(Float(orb.x), Float(orb.y), Float(orb.r), Float(orb.presence)))
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(), let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<VisualUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func count(_ now: CFTimeInterval) {
        if VisualFrames.enabled { VisualFrames.shared.drew(); VisualFrames.shared.heard(plan?.env.shown(heard.level) ?? 0) }
    }

    private func pipeline(_ look: String, format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = Self.pipelines[look] { return p }
        guard let device, let library,
              let frag = library.makeFunction(name: "visual" + look.prefix(1).uppercased() + look.dropFirst()) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "visualVertex")
        d.fragmentFunction = frag
        d.colorAttachments[0].pixelFormat = format
        let p = try? device.makeRenderPipelineState(descriptor: d)
        Self.pipelines[look] = p
        return p
    }

    private static func vec(_ hex: String) -> SIMD3<Float> {
        let c = RGB(hex: hex) ?? RGB(r: 0, g: 0, b: 0)
        return SIMD3(Float(c.r), Float(c.g), Float(c.b))
    }
}

/// The orb as drawn: where, how big and how much of it is there. It eases toward the place the
/// layout keeps for it, so going from the home to the working state it glides and grows, and with
/// words up it shrinks a little and fades where it stands.
struct OrbPlace: Equatable {
    var x = 0.5, y = 0.44, r = 0.0, presence = 0.0
    /// The radius it last had a place for: what it shrinks from as it goes.
    private var home = 0.0

    /// Where the orb sat before layouts placed it: a little above the middle, sized to the narrow side.
    static func legacy(aspect: Double) -> OrbPlace {
        OrbPlace(x: 0.5, y: 0.44, r: 0.19 * min(1, 1.4 * aspect), presence: 1)
    }

    /// Where the plan wants it. No spot: the old place. Away: where it is, a little smaller, gone.
    mutating func goal(_ spot: VisualPlan.Spot?, aspect: Double) -> OrbPlace {
        guard let spot else {
            let g = Self.legacy(aspect: aspect)
            home = g.r
            return g
        }
        if spot.presence > 0, spot.r > 0 {
            home = spot.r
            return OrbPlace(x: spot.x, y: spot.y, r: spot.r, presence: spot.presence)
        }
        return OrbPlace(x: x, y: y, r: (home > 0 ? home : Self.legacy(aspect: aspect).r) * 0.72, presence: 0)
    }

    mutating func snap(to g: OrbPlace) {
        x = g.x; y = g.y; r = g.r; presence = g.presence
    }

    /// Place and size at 9 a second, presence in at 6 and out at 10. Coming back from nothing it
    /// starts at its new place, a little small, and blooms there; it never flies in from the old one.
    mutating func ease(toward g: OrbPlace, dt: Double) {
        guard dt > 0 else { if r == 0 { snap(to: g) }; return }
        if presence < 0.02, g.presence > 0 { x = g.x; y = g.y; r = g.r * 0.72 }
        let k = 1 - exp(-9 * dt), kp = 1 - exp(-(g.presence > presence ? 6.0 : 10.0) * dt)
        x += (g.x - x) * k
        y += (g.y - y) * k
        r += (g.r - r) * k
        presence += (g.presence - presence) * kp
    }

    /// Nothing left to move.
    func settled(_ g: OrbPlace) -> Bool {
        abs(g.x - x) < 0.0015 && abs(g.y - y) < 0.0015 && abs(g.r - r) < 0.0008 && abs(g.presence - presence) < 0.004
    }

    /// Gone from the picture.
    var away: Bool { presence < 0.004 }
}

/// The blob's state weights (YUI-232, action.mjs easeWeights): each 0...1, summing to 1, every
/// one easing toward its target (in at 3.2 a second, out at 2.2), so two shapes overlap for a
/// moment and the blob never snaps.
struct BlobWeights: Equatable {
    static let rateIn = 3.2, rateOut = 2.2
    private(set) var w: [StageAction: Double]
    var action: StageAction

    /// All of it on one state: the start, and every still frame.
    init(_ action: StageAction = .idle) {
        self.action = action
        w = Dictionary(uniqueKeysWithValues: StageAction.allCases.map { ($0, $0 == action ? 1.0 : 0.0) })
    }

    subscript(_ a: StageAction) -> Double { w[a] ?? 0 }

    mutating func ease(toward target: StageAction, dt: Double) {
        var sum = 0.0
        for a in StageAction.allCases {
            let x = w[a] ?? 0, goal = a == target ? 1.0 : 0.0
            let k = 1 - exp(-(goal > x ? Self.rateIn : Self.rateOut) * max(0, dt))
            w[a] = x + (goal - x) * k
            sum += w[a]!
        }
        if sum > 0 { for a in StageAction.allCases { w[a]! /= sum } }
    }

    /// The target holds all but a hair: nothing left to morph. `idle` also asks that it be idle.
    func settled(_ idle: Bool) -> Bool { idle && self[action] > 0.995 }
}
