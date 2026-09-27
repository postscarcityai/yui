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
}

@MainActor
final class VisualRenderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private lazy var library = device?.makeDefaultLibrary()
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var plan: VisualPlan?
    var meter: (() -> LevelMeter.Reading)?

    /// The clock (already at the look's pace), the sound after the envelope, the raw sound and when it was read.
    private var clock = 0.0
    private var heard = LevelMeter.Reading.zero
    private var raw = LevelMeter.Reading.zero
    private var lastFrame: CFTimeInterval = 0
    private var lastMeter: CFTimeInterval = 0

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
        } else {
            view.preferredFramesPerSecond = plan.fps
            view.enableSetNeedsDisplay = false
            if view.isPaused { lastFrame = 0; view.isPaused = false }
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { if plan?.still == true { view.setNeedsDisplay() } }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    private func render(_ view: MTKView) {
        guard let plan, let queue, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let pipeline = pipeline(plan.look, format: view.colorPixelFormat) else { return }
        let now = CACurrentMediaTime()
        if !plan.still {
            let dt = lastFrame == 0 ? 0 : min(now - lastFrame, 0.1)
            lastFrame = now
            clock += dt * plan.speed
            if now - lastMeter >= 1 / VisualPlan.Budget.meterHz {
                raw = meter?() ?? .zero
                lastMeter = now
            }
            let ms = dt * 1000, env = plan.env
            heard = .init(level: env.follow(heard.level, raw.level, dt: ms), low: env.follow(heard.low, raw.low, dt: ms),
                          mid: env.follow(heard.mid, raw.mid, dt: ms), high: env.follow(heard.high, raw.high, dt: ms))
        }
        count(now)

        let size = view.drawableSize
        var u = VisualUniforms(
            res: SIMD2(Float(size.width), Float(size.height)), time: Float(clock), level: Float(plan.env.shown(heard.level)),
            dim: Float(plan.dim), scrim: Float(plan.scrim),
            zone: SIMD2(Float(plan.zone.low), Float(plan.zone.high)),
            a: Self.vec(plan.colors.a), b: Self.vec(plan.colors.b), c: Self.vec(plan.colors.c), ground: Self.vec(plan.colors.ground),
            bands: SIMD3(Float(plan.env.shown(heard.low)), Float(plan.env.shown(heard.mid)), Float(plan.env.shown(heard.high))))
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
        if let p = pipelines[look] { return p }
        guard let device, let library,
              let frag = library.makeFunction(name: "visual" + look.prefix(1).uppercased() + look.dropFirst()) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "visualVertex")
        d.fragmentFunction = frag
        d.colorAttachments[0].pixelFormat = format
        let p = try? device.makeRenderPipelineState(descriptor: d)
        pipelines[look] = p
        return p
    }

    private static func vec(_ hex: String) -> SIMD3<Float> {
        let c = RGB(hex: hex) ?? RGB(r: 0, g: 0, b: 0)
        return SIMD3(Float(c.r), Float(c.g), Float(c.b))
    }
}
