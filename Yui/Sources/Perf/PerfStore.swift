import Foundation
import UIKit

// PerfStore (YUI-102, spec yuigui/spec/PERF.md sections 4 and 5): samples go
// into fixed-bucket histograms here, off the main thread, and leave as yui_perf
// rows in one request: every foreground hour, on going to the background, and
// when a MetricKit payload lands. A failed send keeps its rows (7 days, 500
// rows at most) for the next batch. Rows carry numbers and snake_case names
// only; there is no field a word from a message could go in.

/// PERF.md section 4: bucket edges in ms, plus one bucket above the last.
enum PerfBuckets {
    static let edges: [Double] = [2, 4, 8, 12, 16, 24, 33, 50, 75, 100, 150, 250, 400, 600, 1000, 2000, 5000]
    static var count: Int { edges.count + 1 }

    /// The bucket a sample falls in: the first edge it is under (or on).
    static func index(_ ms: Double) -> Int {
        edges.firstIndex { ms <= $0 } ?? edges.count
    }

    /// p-th percentile (0...1) of a histogram: the bucket where the rank lands,
    /// interpolated inside it. The bucket above the last edge reports its floor.
    static func percentile(_ counts: [Int], _ p: Double) -> Double? {
        let n = counts.reduce(0, +)
        guard n > 0 else { return nil }
        let rank = p * Double(n)
        var seen = 0.0
        for (i, c) in counts.enumerated() where c > 0 {
            if seen + Double(c) >= rank {
                let lo = i == 0 ? 0 : edges[i - 1]
                guard i < edges.count else { return lo }
                let hi = edges[i]
                return lo + (hi - lo) * max(0, min(1, (rank - seen) / Double(c)))
            }
            seen += Double(c)
        }
        return edges.last
    }
}

/// One yui_perf row, exactly the columns the phone may write (migration
/// 20260925110000_yui_perf.sql). `user_id` is added at send time.
struct PerfRow: Codable, Equatable, Sendable {
    var kind: String
    var name: String
    var app_build: Int
    var app_version: String
    var os: String
    var device: String
    var promotion: Bool
    var low_power: Bool
    var thermal: Int
    var period_start: String
    var period_end: String
    var n: Int
    var buckets: [Int]?
    var p50: Double?
    var p95: Double?
    var max: Double?
    var value: Double?
    var stack: [PerfFrame]?
}

/// A stack frame as MetricKit gives it: binary, its UUID, the offset. No symbols, no strings.
struct PerfFrame: Codable, Equatable, Sendable {
    var image: String
    var uuid: String
    var offset: Int
}

/// Where the phone is (PERF.md section 4, "Context on every row").
struct PerfContext: Sendable, Equatable {
    var build: Int
    var version: String
    var os: String
    var device: String
    var promotion: Bool
    var lowPower: Bool
    var thermal: Int

    @MainActor static func now() -> PerfContext {
        PerfContext(build: buildNumber(BuildInfo.build),
                    version: BuildInfo.version,
                    os: UIDevice.current.systemVersion,
                    device: model,
                    promotion: UIScreen.main.maximumFramesPerSecond > 60,
                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    thermal: ProcessInfo.processInfo.thermalState.rawValue)
    }

    /// The build as the table counts it: a test build "125.2" is build 125.
    static func buildNumber(_ s: String?) -> Int {
        s.flatMap { Int($0.split(separator: ".").first ?? "") } ?? 0
    }

    /// "iPhone16,2". The simulator reports the Mac's arch, so ask it which phone it plays.
    static let model: String = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()
}

actor PerfStore {
    static let shared = PerfStore()

    static let maxRows = 500
    static let keepFor: TimeInterval = 7 * 24 * 3600

    /// Hands out a yui_user access token; nil while signed out or on the demo account.
    typealias TokenSource = @Sendable () async throws -> String?
    private var token: TokenSource?
    private var userID: String?
    private var context: PerfContext?

    private var hist: [String: [Int]] = [:]
    private var maxMs: [String: Double] = [:]
    private var memory: [Double] = []
    private var warnings = 0
    private var periodStart = Date()
    private var pending: [PerfRow] = []
    private var sending = false
    private let file: URL?
    /// Tests swap the network out: the JSON body and the bearer token.
    typealias Poster = @Sendable (_ body: Data, _ token: String) async -> Bool
    private var post: Poster?

    init(file: URL? = PerfStore.defaultFile) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([PerfRow].self, from: data) {
            pending = saved
        }
    }

    static var defaultFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "perf-pending.json")
    }

    // MARK: In

    func signedIn(userID: String?, token: TokenSource?) {
        self.userID = userID
        self.token = token
    }

    func setContext(_ c: PerfContext) { context = c }

    func setPoster(_ p: Poster?) { post = p }

    func add(_ name: String, ms: Double) {
        var h = hist[name] ?? Array(repeating: 0, count: PerfBuckets.count)
        h[PerfBuckets.index(ms)] += 1
        hist[name] = h
        maxMs[name] = Swift.max(maxMs[name] ?? 0, ms)
    }

    /// phys_footprint in MB, every 30 s in the foreground and on a memory warning.
    func memorySample(mb: Double, warning: Bool = false) {
        memory.append(mb)
        if warning { warnings += 1 }
    }

    /// MetricKit rows (metrics and diagnostics), queued for the next send.
    func queue(_ rows: [PerfRow]) {
        pending.append(contentsOf: rows)
        trim()
        save()
    }

    // MARK: Out

    /// Closes the current period into rows (nothing if nothing happened).
    func closePeriod(now: Date = Date()) {
        guard let c = context else { return }
        let start = Self.iso(periodStart), end = Self.iso(now)
        func row(_ kind: String, _ name: String) -> PerfRow {
            PerfRow(kind: kind, name: name, app_build: c.build, app_version: c.version, os: c.os, device: c.device,
                    promotion: c.promotion, low_power: c.lowPower, thermal: c.thermal,
                    period_start: start, period_end: end, n: 0)
        }
        for name in hist.keys.sorted() {
            guard let h = hist[name] else { continue }
            var r = row("interval", name)
            r.n = h.reduce(0, +)
            r.buckets = h
            // Interpolating inside a wide bucket can pass the slowest sample; never report past it.
            let top = maxMs[name] ?? .infinity
            r.p50 = PerfBuckets.percentile(h, 0.5).map { Self.round1(Swift.min($0, top)) }
            r.p95 = PerfBuckets.percentile(h, 0.95).map { Self.round1(Swift.min($0, top)) }
            r.max = maxMs[name].map(Self.round1)
            pending.append(r)
        }
        if !memory.isEmpty {
            let sorted = memory.sorted()
            var r = row("memory", "mem_footprint")
            r.n = sorted.count
            r.p50 = Self.round1(sorted[sorted.count / 2])
            r.max = Self.round1(sorted.last!)
            r.value = r.p50
            pending.append(r)
        }
        if warnings > 0 {
            var r = row("memory", "mem_warning")
            r.n = warnings
            r.value = Double(warnings)
            pending.append(r)
        }
        hist = [:]
        maxMs = [:]
        memory = []
        warnings = 0
        periodStart = now
        trim()
        save()
    }

    /// Closes the period and sends everything waiting, in one request.
    @discardableResult
    func flush(now: Date = Date()) async -> Bool {
        closePeriod(now: now)
        guard !sending, !pending.isEmpty, let userID, let token else { return false }
        sending = true
        defer { sending = false }
        guard let bearer = try? await token() else { return false }
        let batch = pending
        guard let body = try? JSONSerialization.data(withJSONObject: batch.map { Self.json($0, userID: userID) })
        else { return false }
        let ok = await (post ?? Self.send)(body, bearer)
        if ok {
            // Rows queued while this was in flight stay.
            pending.removeFirst(Swift.min(batch.count, pending.count))
            save()
        }
        return ok
    }

    var waiting: [PerfRow] { pending }

    // MARK: Keeping

    /// At most 7 days and 500 rows; the oldest go first.
    private func trim(now: Date = Date()) {
        let cutoff = Self.iso(now.addingTimeInterval(-Self.keepFor))
        pending.removeAll { $0.period_end < cutoff }
        if pending.count > Self.maxRows { pending.removeFirst(pending.count - Self.maxRows) }
    }

    private func save() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pending).write(to: file, options: .atomic)
    }

    // MARK: Wire

    static func json(_ r: PerfRow, userID: String) -> [String: Any] {
        var d: [String: Any] = [
            "user_id": userID, "kind": r.kind, "name": r.name, "app_build": r.app_build,
            "app_version": r.app_version, "os": r.os, "device": r.device, "promotion": r.promotion,
            "low_power": r.low_power, "thermal": r.thermal, "period_start": r.period_start,
            "period_end": r.period_end, "n": r.n,
        ]
        // Every row in a batch carries every key (PostgREST refuses mixed keys): null when absent.
        let none = NSNull()
        d["buckets"] = r.buckets ?? none
        d["p50"] = r.p50 ?? none
        d["p95"] = r.p95 ?? none
        d["max"] = r.max ?? none
        d["value"] = r.value ?? none
        d["stack"] = r.stack.map { $0.map { ["image": $0.image, "uuid": $0.uuid, "offset": $0.offset] } } ?? none
        return d
    }

    @Sendable static func send(_ body: Data, _ bearer: String) async -> Bool {
        var req = URLRequest(url: YuiBackend.url.appending(path: "rest/v1/yui_perf"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(YuiBackend.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        // A 4xx other than a rate limit will never go through: drop it rather than retry forever.
        if (400..<500).contains(http.statusCode), http.statusCode != 429, http.statusCode != 401 {
            if PerfSettings.speedOn { Perf.log.error("perf send refused \(http.statusCode)") }
            return true
        }
        return (200..<300).contains(http.statusCode)
    }

    static func iso(_ d: Date) -> String {
        d.formatted(.iso8601)
    }

    static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
