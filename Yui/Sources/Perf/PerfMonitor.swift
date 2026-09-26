import Foundation
import MetricKit
import UIKit

// The rest of the phone side of PERF.md (YUI-102): MetricKit at launch, memory
// every 30 s in the foreground and on warnings, the hourly batch, and the batch
// on going to the background. Started once from the app delegate.

@MainActor
final class PerfMonitor {
    static let shared = PerfMonitor()

    private let metrics = PerfMetrics()
    private var memoryTimer: Timer?
    private var batchTimer: Timer?
    private var started = false
    /// A cold launch also posts willEnterForeground under scenes: resume counts only after the first activation.
    private var activeOnce = false

    func start() {
        guard !started else { return }
        started = true
        _ = Perf.processStart
        MXMetricManager.shared.add(metrics)
        let store = PerfStore.shared
        let ctx = PerfContext.now()
        Task.detached { await store.setContext(ctx) }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PerfMonitor.sampleMemory(warning: true) }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if PerfMonitor.shared.activeOnce { Perf.shared.begin(.resume) } }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Perf.shared.end(.resume)
                // Taps are timed from the window (YUI-101); attach is a no-op the second time.
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    scene.windows.forEach(TapClock.attach)
                }
                if !PerfMonitor.shared.activeOnce { Perf.shared.watchIfVerbose() }
                PerfMonitor.shared.activeOnce = true
                PerfMonitor.shared.foreground(true)
            }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PerfMonitor.shared.foreground(false) }
        }
        for n in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let ctx = PerfContext.now()
                    Task.detached { await PerfStore.shared.setContext(ctx) }
                }
            }
        }
    }

    /// Signed in (not the demo account): rows go out with this account's token.
    func signedIn(_ account: Account?) {
        let userID = account?.session?.userID
        let live = userID != nil && userID != "demo"
        var source: PerfStore.TokenSource?
        if live, let account { source = { @Sendable @MainActor in try await account.validAccessToken() } }
        Task.detached { await PerfStore.shared.signedIn(userID: live ? userID : nil, token: source) }
    }

    private func foreground(_ on: Bool) {
        memoryTimer?.invalidate()
        batchTimer?.invalidate()
        memoryTimer = nil
        batchTimer = nil
        if on {
            let ctx = PerfContext.now()
            Task.detached { await PerfStore.shared.setContext(ctx) }
            Self.sampleMemory()
            memoryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { PerfMonitor.sampleMemory() }
            }
            batchTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                Task.detached { await PerfStore.shared.flush() }
            }
        } else {
            // One batch on the way out; the system gives us a moment to send it.
            let task = UIApplication.shared.beginBackgroundTask(withName: "yui-perf", expirationHandler: nil)
            Task.detached {
                await PerfStore.shared.flush()
                await MainActor.run { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    static func sampleMemory(warning: Bool = false) {
        guard let mb = footprintMB() else { return }
        if Perf.shared.verbose { Perf.log.debug("perf mem_footprint \(mb, format: .fixed(precision: 1), privacy: .public) MB") }
        Task.detached(priority: .utility) { await PerfStore.shared.memorySample(mb: mb, warning: warning) }
    }

    /// What iOS counts against the app (task_vm_info.phys_footprint), in MB.
    nonisolated static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}

/// The MetricKit subscriber: daily metrics and diagnostics as they happen,
/// turned into rows and sent at once. Only delivered to people who share
/// analytics with developers, so this half is sparse by design.
final class PerfMetrics: NSObject, MXMetricManagerSubscriber, Sendable {
    func didReceive(_ payloads: [MXMetricPayload]) {
        let rows = payloads.flatMap(PerfMetricRows.rows)
        Task.detached {
            await PerfStore.shared.queue(rows)
            await PerfStore.shared.flush()
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let rows = payloads.flatMap(PerfMetricRows.rows)
        Task.detached {
            await PerfStore.shared.queue(rows)
            await PerfStore.shared.flush()
        }
    }
}

/// MetricKit payloads as yui_perf rows. Names the report reads (PERF.md section 3):
/// metrics hang_rate (s/h), hitch_ratio (ms/s), mem_peak and mem_avg (MB),
/// cpu_time and fg_time (s), launch_mk and resume_mk (histograms in PERF.md
/// buckets); diagnostics hang (value = s), crash, cpu_exception, disk_write.
enum PerfMetricRows {
    struct Meta {
        var build: Int, version: String, os: String, device: String
        var start: Date, end: Date
    }

    static func meta(_ m: MXMetaData?, start: Date, end: Date) -> Meta {
        let osLine = m?.osVersion ?? ""
        return Meta(build: PerfContext.buildNumber(m?.applicationBuildVersion ?? BuildInfo.build),
                    version: BuildInfo.version,
                    os: version(in: osLine) ?? osVersion,
                    device: m?.deviceType ?? PerfContext.model,
                    start: start, end: max(start, end))
    }

    /// "26.0.1": digits and dots only, as yui_perf's check wants.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// "iPhone OS 26.1 (23B85)" -> "26.1".
    static func version(in os: String) -> String? {
        os.split(separator: " ").first { $0.first?.isNumber == true && $0.contains(".") }.map(String.init)
    }

    static func row(_ m: Meta, kind: String, name: String) -> PerfRow {
        PerfRow(kind: kind, name: name, app_build: m.build, app_version: m.version, os: m.os, device: m.device,
                promotion: false, low_power: false, thermal: 0,
                period_start: PerfStore.iso(m.start), period_end: PerfStore.iso(m.end), n: 0)
    }

    static func rows(_ p: MXMetricPayload) -> [PerfRow] {
        let m = meta(p.metaData, start: p.timeStampBegin, end: p.timeStampEnd)
        var out: [PerfRow] = []
        func value(_ name: String, _ v: Double?, n: Int = 1) {
            guard let v, v.isFinite else { return }
            var r = row(m, kind: "metrics", name: name)
            r.value = PerfStore.round1(v)
            r.n = n
            out.append(r)
        }
        let fg = p.applicationTimeMetrics?.cumulativeForegroundTime.converted(to: .seconds).value
        value("fg_time", fg)
        if let h = p.applicationResponsivenessMetrics?.histogrammedApplicationHangTime {
            let (_, total, count) = rebucket(h)
            if let fg, fg > 0 { value("hang_rate", total / 1000 / (fg / 3600), n: count) }
        }
        value("hitch_ratio", p.animationMetrics?.scrollHitchTimeRatio.value)
        value("mem_peak", p.memoryMetrics?.peakMemoryUsage.converted(to: .megabytes).value)
        value("mem_avg", p.memoryMetrics?.averageSuspendedMemory.averageMeasurement.converted(to: .megabytes).value)
        value("cpu_time", p.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value)
        func hist(_ name: String, _ h: MXHistogram<UnitDuration>?) {
            guard let h else { return }
            let (b, _, count) = rebucket(h)
            guard count > 0 else { return }
            var r = row(m, kind: "metrics", name: name)
            r.n = count
            r.buckets = b
            r.p50 = PerfBuckets.percentile(b, 0.5).map(PerfStore.round1)
            r.p95 = PerfBuckets.percentile(b, 0.95).map(PerfStore.round1)
            out.append(r)
        }
        hist("launch_mk", p.applicationLaunchMetrics?.histogrammedTimeToFirstDraw)
        hist("resume_mk", p.applicationLaunchMetrics?.histogrammedApplicationResumeTime)
        return out
    }

    /// A MetricKit histogram in PERF.md buckets (each of its buckets lands on its
    /// midpoint), the total time in ms and the count.
    static func rebucket(_ h: MXHistogram<UnitDuration>) -> ([Int], Double, Int) {
        var b = Array(repeating: 0, count: PerfBuckets.count)
        var total = 0.0, count = 0
        let e = h.bucketEnumerator
        while let bucket = e.nextObject() as? MXHistogramBucket<UnitDuration> {
            let lo = bucket.bucketStart.converted(to: .milliseconds).value
            let hi = bucket.bucketEnd.converted(to: .milliseconds).value
            let mid = (lo + hi) / 2
            b[PerfBuckets.index(mid)] += bucket.bucketCount
            total += mid * Double(bucket.bucketCount)
            count += bucket.bucketCount
        }
        return (b, total, count)
    }

    static func rows(_ p: MXDiagnosticPayload) -> [PerfRow] {
        var out: [PerfRow] = []
        func add(_ name: String, _ d: MXDiagnostic, tree: MXCallStackTree, seconds: Double?) {
            let m = meta(d.metaData, start: p.timeStampBegin, end: p.timeStampEnd)
            var r = row(m, kind: "diagnostic", name: name)
            r.n = 1
            r.value = seconds.map(PerfStore.round1)
            let f = frames(tree.jsonRepresentation())
            r.stack = f.isEmpty ? nil : f
            out.append(r)
        }
        for d in p.hangDiagnostics ?? [] {
            add("hang", d, tree: d.callStackTree, seconds: d.hangDuration.converted(to: .seconds).value)
        }
        for d in p.crashDiagnostics ?? [] { add("crash", d, tree: d.callStackTree, seconds: nil) }
        for d in p.cpuExceptionDiagnostics ?? [] {
            add("cpu_exception", d, tree: d.callStackTree, seconds: d.totalCPUTime.converted(to: .seconds).value)
        }
        for d in p.diskWriteExceptionDiagnostics ?? [] { add("disk_write", d, tree: d.callStackTree, seconds: nil) }
        return out
    }

    /// The call stack tree's JSON as frames, top first: the attributed thread
    /// (or the first), down its first child at each level. Only binary name, UUID
    /// and offset are kept; MetricKit's other keys never leave the phone.
    static func frames(_ json: Data, limit: Int = 32) -> [PerfFrame] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var level = stack?["callStackRootFrames"] as? [[String: Any]]
        var out: [PerfFrame] = []
        while let f = level?.first, out.count < limit {
            if let image = (f["binaryName"] as? String).map(cleanImage), !image.isEmpty,
               let uuid = f["binaryUUID"] as? String, uuid.count >= 32, uuid.count <= 36,
               uuid.allSatisfy({ $0.isHexDigit || $0 == "-" }),
               var offset = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.intValue {
                // MetricKit often puts the image's load address in this field; the
                // offset is then the frame address minus it.
                if let address = (f["address"] as? NSNumber)?.intValue, address > offset { offset = address - offset }
                if offset >= 0 { out.append(PerfFrame(image: image, uuid: uuid, offset: offset)) }
            }
            level = f["subFrames"] as? [[String: Any]]
        }
        return out
    }

    /// A binary name as the table takes it: letters, digits and `_.+-`, 64 at most.
    static func cleanImage(_ s: String) -> String {
        String(s.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_.+-".contains($0)) }.prefix(64))
    }
}
