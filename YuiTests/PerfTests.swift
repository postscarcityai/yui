import XCTest
@testable import Yui

/// Speed reporting (YUI-102, spec yuigui/spec/PERF.md): the fixed buckets and
/// their percentiles, the rows a period closes into (numbers only), the batch
/// the phone sends, what it keeps when a send fails, and MetricKit stacks as
/// frames with no strings.
final class PerfTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "perf-\(UUID().uuidString).json")
    }

    private let ctx = PerfContext(build: 125, version: "0.2.0", os: "26.1", device: "iPhone18,1",
                                  promotion: true, lowPower: false, thermal: 1)

    func testBucketEdges() {
        XCTAssertEqual(PerfBuckets.count, 18)
        XCTAssertEqual(PerfBuckets.index(0), 0)
        XCTAssertEqual(PerfBuckets.index(2), 0, "an edge belongs to the bucket under it")
        XCTAssertEqual(PerfBuckets.index(2.1), 1)
        XCTAssertEqual(PerfBuckets.index(16.7), 5)
        XCTAssertEqual(PerfBuckets.index(5000), 16)
        XCTAssertEqual(PerfBuckets.index(9000), 17, "above the last edge: the overflow bucket")
    }

    func testPercentilesInterpolateInsideTheBucket() {
        var h = Array(repeating: 0, count: PerfBuckets.count)
        XCTAssertNil(PerfBuckets.percentile(h, 0.5))
        h[PerfBuckets.index(10)] = 100  // all in 8...12
        XCTAssertEqual(PerfBuckets.percentile(h, 0.5)!, 10, accuracy: 0.001)
        XCTAssertEqual(PerfBuckets.percentile(h, 0.95)!, 11.8, accuracy: 0.001)
        h[PerfBuckets.index(40)] = 100  // and as many in 33...50
        XCTAssertEqual(PerfBuckets.percentile(h, 0.5)!, 12, accuracy: 0.001)
        XCTAssertEqual(PerfBuckets.percentile(h, 0.95)!, 33 + 17 * 0.9, accuracy: 0.001)
        var over = Array(repeating: 0, count: PerfBuckets.count)
        over[17] = 3
        XCTAssertEqual(PerfBuckets.percentile(over, 0.95), 5000, "the overflow bucket reports its floor")
    }

    func testAPeriodClosesIntoNumbersOnlyRows() async {
        let store = PerfStore(file: nil)
        await store.setContext(ctx)
        for ms in [9.0, 11, 14, 30] { await store.add("keystroke_render", ms: ms) }
        await store.add("send_bubble", ms: 20)
        for mb in [120.0, 140, 131] { await store.memorySample(mb: mb) }
        await store.memorySample(mb: 150, warning: true)
        await store.closePeriod()
        let rows = await store.waiting
        XCTAssertEqual(rows.map(\.name), ["keystroke_render", "send_bubble", "mem_footprint", "mem_warning"])
        let keys = rows[0]
        XCTAssertEqual(keys.kind, "interval")
        XCTAssertEqual(keys.n, 4)
        XCTAssertEqual(keys.buckets?.count, 18)
        XCTAssertEqual(keys.buckets?.reduce(0, +), 4)
        XCTAssertEqual(keys.max, 30)
        XCTAssertLessThanOrEqual(keys.p95!, 30, "a percentile never passes the slowest sample")
        XCTAssertEqual(keys.app_build, 125)
        XCTAssertEqual(keys.device, "iPhone18,1")
        XCTAssertTrue(keys.promotion)
        XCTAssertEqual(keys.thermal, 1)
        let mem = rows[2]
        XCTAssertEqual(mem.kind, "memory")
        XCTAssertEqual(mem.n, 4)
        XCTAssertEqual(mem.max, 150)
        XCTAssertEqual(mem.p50, 140)
        XCTAssertEqual(rows[3].value, 1)
        // Every name fits the table's check, and nothing but numbers rides along.
        let re = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]{1,40}$")
        for r in rows {
            XCTAssertNotNil(re.firstMatch(in: r.name, range: NSRange(r.name.startIndex..., in: r.name)), r.name)
            XCTAssertNil(r.stack)
        }
        // A period with nothing in it adds nothing.
        await store.closePeriod()
        let again = await store.waiting
        XCTAssertEqual(again.count, 4)
    }

    func testTheBatchIsOneRequestWithOnlyTheAllowedColumns() async throws {
        let store = PerfStore(file: nil)
        await store.setContext(ctx)
        let sent = Sent()
        await store.setPoster { body, token in await sent.put(body, token); return true }
        await store.add("thread_open", ms: 140)
        // Signed out: nothing goes, the rows wait.
        let signedOut = await store.flush()
        XCTAssertFalse(signedOut)
        await store.signedIn(userID: "00000000-0000-0000-0000-000000000001", token: { "tok" })
        let ok = await store.flush()
        XCTAssertTrue(ok)
        let got = await sent.last
        let (body, token) = try XCTUnwrap(got)
        XCTAssertEqual(token, "tok")
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        let allowed: Set = ["user_id", "kind", "name", "app_build", "app_version", "os", "device", "promotion",
                            "low_power", "thermal", "period_start", "period_end", "n", "buckets", "p50", "p95",
                            "max", "value", "stack"]
        XCTAssertTrue(Set(rows[0].keys).isSubset(of: allowed), "\(rows[0].keys)")
        XCTAssertEqual(rows[0]["user_id"] as? String, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(rows[0]["name"] as? String, "thread_open")
        XCTAssertEqual(Set(rows[0].keys), allowed, "every row carries every column, null when absent")
        XCTAssertTrue(rows[0]["stack"] is NSNull)
        let waiting = await store.waiting
        XCTAssertTrue(waiting.isEmpty, "sent rows are gone")
    }

    func testAFailedSendKeepsRowsOnDiskUpTo500() async {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = PerfStore(file: file)
        await store.setContext(ctx)
        await store.signedIn(userID: "u", token: { "tok" })
        await store.setPoster { _, _ in false }
        await store.add("swipe", ms: 390)
        let ok = await store.flush()
        XCTAssertFalse(ok)
        // A new launch finds them.
        let reopened = await PerfStore(file: file).waiting
        XCTAssertEqual(reopened.map(\.name), ["swipe"])
        // 500 at most: the oldest go.
        let many = (0..<520).map { i in
            PerfRow(kind: "metrics", name: "fg_time", app_build: 1, app_version: "0.2.0", os: "26.1", device: "iPhone18,1",
                    promotion: false, low_power: false, thermal: 0, period_start: PerfStore.iso(.now),
                    period_end: PerfStore.iso(.now), n: i)
        }
        await store.queue(many)
        let kept = await store.waiting
        XCTAssertEqual(kept.count, 500)
        XCTAssertEqual(kept.last?.n, 519)
    }

    func testRowsOlderThanSevenDaysAreDropped() async {
        let store = PerfStore(file: nil)
        let old = Date.now.addingTimeInterval(-8 * 24 * 3600)
        let row = PerfRow(kind: "metrics", name: "fg_time", app_build: 1, app_version: "0.2.0", os: "26.1",
                          device: "iPhone18,1", promotion: false, low_power: false, thermal: 0,
                          period_start: PerfStore.iso(old), period_end: PerfStore.iso(old), n: 1)
        await store.queue([row])
        let kept = await store.waiting
        XCTAssertTrue(kept.isEmpty)
    }

    func testStacksAreFramesOnly() {
        let json = """
        {"callStackPerThread": true, "callStacks": [
          {"threadAttributed": false, "callStackRootFrames": [{"binaryName": "libsystem_kernel.dylib", "binaryUUID": "AAAA", "offsetIntoBinaryTextSegment": 1, "sampleCount": 1}]},
          {"threadAttributed": true, "callStackRootFrames": [
            {"binaryName": "Yui", "binaryUUID": "0F3C8B6E-1111-2222-3333-444455556666", "offsetIntoBinaryTextSegment": 4294967296,
             "address": 4295090752, "sampleCount": 20,
             "subFrames": [{"binaryName": "SwiftUI", "binaryUUID": "5A1B2C3D4E5F60718293A4B5C6D7E8F9", "offsetIntoBinaryTextSegment": 42, "sampleCount": 20}]}
          ]}
        ]}
        """
        let frames = PerfMetricRows.frames(Data(json.utf8))
        XCTAssertEqual(frames, [
            PerfFrame(image: "Yui", uuid: "0F3C8B6E-1111-2222-3333-444455556666", offset: 123456),
            PerfFrame(image: "SwiftUI", uuid: "5A1B2C3D4E5F60718293A4B5C6D7E8F9", offset: 42),
        ])
        XCTAssertEqual(PerfMetricRows.frames(Data("not json".utf8)), [])
        XCTAssertEqual(PerfMetricRows.cleanImage("My App (beta).dylib"), "MyAppbeta.dylib")
        XCTAssertTrue(PerfMetricRows.osVersion.allSatisfy { $0.isNumber || $0 == "." })
    }

    func testTestBuildsCountAsTheirCommitBuild() {
        XCTAssertEqual(PerfContext.buildNumber("125.2"), 125)
        XCTAssertEqual(PerfContext.buildNumber("126"), 126)
        XCTAssertEqual(PerfContext.buildNumber(nil), 0)
        XCTAssertEqual(PerfContext.buildNumber("?"), 0)
    }

    func testOSVersionFromMetricKit() {
        XCTAssertEqual(PerfMetricRows.version(in: "iPhone OS 26.1 (23B85)"), "26.1")
        XCTAssertNil(PerfMetricRows.version(in: ""))
    }

    func testSpeedSwitchIsDevOnly() {
        // Unit tests run the Xcode (DEBUG) build, which counts as Dev.
        XCTAssertTrue(PerfSettings.available)
    }
}

private actor Sent {
    var last: (Data, String)?
    func put(_ body: Data, _ token: String) { last = (body, token) }
}
