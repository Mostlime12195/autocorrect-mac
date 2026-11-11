import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import Engine

/// Scoring a big candidate set in chunks gives bit-identical scores and a much lower peak than one big batch (every row
/// computes full-vocab logits, so the batch size sets the peak). Needs AC_MODEL_DIR with m2s.step.int4m.ort.
final class MemoryTests: XCTestCase {
    #if canImport(Darwin)
    /// current resident bytes of this process
    static func resident() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
    #else
    static func resident() -> Int { 0 }
    #endif

    /// runs `body` while a thread samples resident memory; returns the highest sample minus the level before
    static func peakGrowth(_ body: () throws -> Void) rethrows -> Int {
        let base = resident()
        let lock = NSLock()
        var peak = base, stop = false
        let t = Thread {
            while true {
                lock.lock(); let s = stop; lock.unlock()
                if s { return }
                let r = MemoryTests.resident()
                lock.lock(); if r > peak { peak = r }; lock.unlock()
                usleep(500)
            }
        }
        t.start()
        defer { lock.lock(); stop = true; lock.unlock() }
        try body()
        lock.lock(); let p = max(peak, resident()); lock.unlock()
        return p - base
    }

    func testChunkedScoringIsIdenticalAndLighter() throws {
        let path = try Fixtures.modelPath("m2s.step.int4m.ort")
        let ref = Fixtures.json("pipeline_m2s.json") as! [String: Any]
        let m = ref["meta"] as! [String: Any]
        let meta = StepMeta(nKvHeads: (m["n_kv_heads"] as! NSNumber).intValue, headDim: (m["head_dim"] as! NSNumber).intValue,
                            convKernel: (m["conv_kernel"] as! NSNumber).intValue, dModel: (m["d_model"] as! NSNumber).intValue,
                            stateNames: m["state_names"] as! [String])
        let step = try StepModel.open(path: path, meta: meta, threads: 4)
        defer { step.close() }
        let left = "hey are you coming to the party tonight or are you staying home because i think everyone else is going and"
        let words = ["not", "now", "nit", "know", "note", "noted", "nothing", "never", "new", "next", "nice", "night", "nine", "no",
                     "yes", "yeah", "yep", "maybe", "might", "mind", "mine", "miss", "missed", "more", "most", "much", "must", "my",
                     "the", "then", "there", "their", "they", "them", "this", "that", "those", "though", "through", "thought"]
        var reqs: [LmReq] = []
        for w in words { for suffix in ["", "s", "ed", "ing", "er"] { reqs.append(LmReq(left, " " + w + suffix)) } }
        reqs += words.map { LmReq(left, " " + $0 + ".") }
        XCTAssertGreaterThanOrEqual(reqs.count, 200)

        func score(_ rows: Int) throws -> [Double] {
            let sc = NeuralScorer(tok: Fixtures.tokM2, step: step, styleId: 250)
            sc.maxRows = rows
            return try sc.score(reqs)
        }
        let mbs = { (b: Int) in String(format: "%.0f", Double(b) / 1_048_576) }
        let r0 = Self.resident()
        _ = try score(32)   // warm-up: first-run allocations out of the measurement
        let r1 = Self.resident()
        var chunked: [Double] = [], whole: [Double] = [], tiny: [Double] = []
        let gChunked = try Self.peakGrowth { chunked = try score(32) }
        let rC = Self.resident()
        let gWhole = try Self.peakGrowth { whole = try score(Int.max) }
        let rW = Self.resident()
        tiny = try score(5)
        let r3 = Self.resident()
        let mb = { (b: Int) in mbs(b) + " MB" }
        print("RSSLOG resident MB: session open \(mbs(r0)), after chunked warm-up \(mbs(r1)), after chunked run \(mbs(rC)), after one-batch run \(mbs(rW)), after chunk-5 run \(mbs(r3))")
        print("peak growth over \(reqs.count) candidates: chunks of 32 \(mb(gChunked)), one batch \(mb(gWhole)); scores identical: \(chunked == whole && chunked == tiny)")
        XCTAssertEqual(chunked, whole, "chunked scores differ from one big batch")
        XCTAssertEqual(chunked, tiny, "chunk size 5 differs")
        XCTAssertTrue(chunked.allSatisfy { $0.isFinite })
        #if canImport(Darwin)
        XCTAssertLessThan(gChunked, gWhole / 2, "chunking should at least halve the peak")
        #endif
    }
}
