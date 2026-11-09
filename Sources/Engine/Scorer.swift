import Foundation
import COrt

public let MAX_CTX = 64
/// continuation suffix = end of message: score </s> instead of the word boundary
public let EOT = "\u{3}"

/// One LM request: log P(cont + word boundary | left).
public struct LmReq: Equatable {
    public let left: String
    public let cont: String
    public init(_ left: String, _ cont: String) { self.left = left; self.cont = cont }
}

/// The decoder's only view of the language model. NeuralScorer runs the batched step graph; the tree graph
/// (all candidates of a word in one ORT call, android perf branch) slots in as another implementation.
public protocol LmScorer: AnyObject {
    func score(_ reqs: [LmReq]) throws -> [Double]
}

/// Step-graph layout (web/export_step.py), from the model manifest.
public struct StepMeta {
    public let nKvHeads: Int
    public let headDim: Int
    public let convKernel: Int
    public let dModel: Int
    public let stateNames: [String]
    public init(nKvHeads: Int, headDim: Int, convKernel: Int, dModel: Int, stateNames: [String]) {
        self.nKvHeads = nKvHeads; self.headDim = headDim; self.convKernel = convKernel; self.dModel = dModel; self.stateNames = stateNames
    }
}

/// Recurrent state after a token prefix: per-name data + shape, the attention mask, last-token log-probs.
public final class LmState {
    let data: [String: [Float]]
    let shapes: [String: [Int64]]
    let mask: [Bool]
    let last: [Float]?
    init(data: [String: [Float]], shapes: [String: [Int64]], mask: [Bool], last: [Float]?) {
        self.data = data; self.shapes = shapes; self.mask = mask; self.last = last
    }
}

struct StepOutput { let tokLp: [Float]; let bnd: [Float]; let n: Int; let state: LmState? }

/// A named input tensor for the C shim.
struct Feed {
    let name: String
    let type: Int32
    let bytes: [UInt8]
    let shape: [Int64]

    init(_ name: String, int64 v: [Int64], _ shape: [Int64]) {
        self.name = name; type = Int32(AC_INT64); self.shape = shape
        bytes = v.withUnsafeBytes { Array($0) }
    }
    init(_ name: String, float v: [Float], _ shape: [Int64]) {
        self.name = name; type = Int32(AC_FLOAT); self.shape = shape
        bytes = v.withUnsafeBytes { Array($0) }
    }
    init(_ name: String, bool v: [Bool], _ shape: [Int64]) {
        self.name = name; type = Int32(AC_BOOL); self.shape = shape
        bytes = v.map { $0 ? 1 : 0 }
    }
    init(_ name: String, int32 v: [Int32], _ shape: [Int64]) {
        self.name = name; type = Int32(AC_INT32); self.shape = shape
        bytes = v.withUnsafeBytes { Array($0) }
    }
}

/// An onnxruntime session over a model file (memory-mapped), through the C shim.
public final class OrtSessionHandle {
    private var s: OpaquePointer?
    public let inputNames: [String]

    public init(path: String, threads: Int, ortFormat: Bool) throws {
        var err = [CChar](repeating: 0, count: 1024)
        let errLen = err.count
        guard let h = ac_session_open(path, Int32(threads), ortFormat ? 1 : 0, &err, errLen) else {
            throw EngineError.ort(String(cString: err))
        }
        s = h
        var names: [String] = []
        for i in 0..<ac_session_input_count(h) {
            var buf = [CChar](repeating: 0, count: 256)
            if ac_session_input_name(h, i, &buf, 256) == 0 { names.append(String(cString: buf)) }
        }
        inputNames = names
    }

    public static var ortVersion: String { String(cString: ac_ort_version()) }

    var isOpen: Bool { s != nil }

    /// -> output name -> (data, shape)
    func run(_ feeds: [Feed], outputs: [String]) throws -> [String: ([Float], [Int64])] {
        guard let s = s else { throw EngineError.closed }
        // keep every buffer alive and pinned for the call
        let nameC = feeds.map { strdup($0.name)! }
        let outC = outputs.map { strdup($0)! }
        let outPtrs: [UnsafePointer<CChar>?] = outC.map { UnsafePointer($0) }
        defer { nameC.forEach { free($0) }; outC.forEach { free($0) } }
        let dataBufs = feeds.map { f -> UnsafeMutableRawPointer in
            let p = UnsafeMutableRawPointer.allocate(byteCount: max(f.bytes.count, 1), alignment: 16)
            f.bytes.withUnsafeBytes { if $0.count > 0 { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
            return p
        }
        let shapeBufs = feeds.map { f -> UnsafeMutablePointer<Int64> in
            let p = UnsafeMutablePointer<Int64>.allocate(capacity: max(f.shape.count, 1))
            for (i, d) in f.shape.enumerated() { p[i] = d }
            return p
        }
        defer { dataBufs.forEach { $0.deallocate() }; shapeBufs.forEach { $0.deallocate() } }
        var inputs = (0..<feeds.count).map { i in
            AcInput(name: UnsafePointer(nameC[i]), type: feeds[i].type, data: UnsafeRawPointer(dataBufs[i]),
                    shape: UnsafePointer(shapeBufs[i]), rank: feeds[i].shape.count)
        }
        let nIn = inputs.count, nOut = outputs.count
        var outs = [AcOutput](repeating: AcOutput(), count: nOut)
        var err = [CChar](repeating: 0, count: 1024)
        let errLen = err.count
        let rc = outPtrs.withUnsafeBufferPointer { onames in
            ac_session_run(s, &inputs, nIn, onames.baseAddress, nOut, &outs, &err, errLen)
        }
        if rc != 0 { throw EngineError.ort(String(cString: err)) }
        defer { ac_outputs_free(&outs, nOut) }
        var res: [String: ([Float], [Int64])] = [:]
        for (i, name) in outputs.enumerated() {
            let o = outs[i]
            let data = o.count > 0 ? Array(UnsafeBufferPointer(start: o.data, count: o.count)) : []
            let shape = withUnsafeBytes(of: o.shape) { raw in Array(raw.bindMemory(to: Int64.self).prefix(o.rank)) }
            res[name] = (data, shape)
        }
        return res
    }

    public func close() {
        if let h = s { ac_session_close(h) }
        s = nil
    }

    deinit { close() }
}

/// One step graph (port of StepModel in Scorer.kt / web/site/models.js).
public final class StepModel {
    public let session: OrtSessionHandle
    public let meta: StepMeta
    public private(set) var closed = false
    /// timing counters
    public var runs = 0
    public var ortSeconds = 0.0

    public init(session: OrtSessionHandle, meta: StepMeta) {
        self.session = session; self.meta = meta
    }

    public static func open(path: String, meta: StepMeta, threads: Int = 4) throws -> StepModel {
        let s = try OrtSessionHandle(path: path, threads: threads, ortFormat: path.hasSuffix(".ort"))
        return StepModel(session: s, meta: meta)
    }

    /// Tree graph (one row of tokens laid out as a token tree, android_export/tree_graph.py): not wired up yet, the
    /// batched path below is used. NeuralScorer checks this to pick the path once the tree runner lands.
    public var isTree: Bool { session.inputNames.contains("tree_mask") }

    func fresh() -> LmState {
        var d: [String: [Float]] = [:], s: [String: [Int64]] = [:]
        for n in meta.stateNames {
            if n.hasPrefix("k") || n.hasPrefix("v") {
                d[n] = [Float](repeating: 0, count: meta.nKvHeads * meta.headDim)
                s[n] = [1, Int64(meta.nKvHeads), 1, Int64(meta.headDim)]
            } else {
                d[n] = [Float](repeating: 0, count: (meta.convKernel - 1) * meta.dModel)
                s[n] = [1, Int64(meta.convKernel - 1), Int64(meta.dModel)]
            }
        }
        return LmState(data: d, shapes: s, mask: [false], last: nil)
    }

    /// rows: token lists (right-padded with 0). keepState: return the present state + last-token log-probs (single row).
    func run(_ rows: [[Int]], pos0: Int, state: LmState, keepState: Bool) throws -> StepOutput {
        if closed { throw EngineError.closed }
        let b = rows.count
        let n = rows.map { $0.count }.max() ?? 0
        var ids = [Int64](repeating: 0, count: b * n)
        var nxt = [Int64](repeating: 0, count: b * n)
        for (r, row) in rows.enumerated() {
            for j in 0..<row.count {
                ids[r * n + j] = Int64(row[j])
                if j > 0 { nxt[r * n + j - 1] = Int64(row[j]) }
            }
        }
        var feeds: [Feed] = [
            Feed("ids", int64: ids, [Int64(b), Int64(n)]),
            Feed("next_ids", int64: nxt, [Int64(b), Int64(n)]),
            Feed("pos", int64: (0..<n).map { Int64(pos0 + $0) }, [Int64(n)]),
            Feed("past_mask", bool: state.mask, [Int64(state.mask.count)]),
        ]
        for nm in meta.stateNames { feeds.append(Feed("past_\(nm)", float: state.data[nm]!, state.shapes[nm]!)) }
        var want = ["tok_lp", "bnd"]
        if keepState { want.append("last_lp"); want += meta.stateNames.map { "present_\($0)" } }
        let t0 = Date()
        let res = try session.run(feeds, outputs: want)
        ortSeconds += Date().timeIntervalSince(t0); runs += 1
        var st: LmState? = nil
        if keepState {
            var d: [String: [Float]] = [:], s: [String: [Int64]] = [:]
            for nm in meta.stateNames { let o = res["present_\(nm)"]!; d[nm] = o.0; s[nm] = o.1 }
            let last = res["last_lp"]!.0
            let v = last.count / max(b, 1)
            st = LmState(data: d, shapes: s, mask: state.mask + [Bool](repeating: true, count: n), last: Array(last[0..<v]))
        }
        return StepOutput(tokLp: res["tok_lp"]!.0, bnd: res["bnd"]!.0, n: n, state: st)
    }

    public func close() { closed = true; session.close() }
}

/// scorers.NeuralScorer.score() on the step graph (port of NeuralScorer in Scorer.kt): the shared left context runs
/// once (batch 1), all candidates of the slot run in one batch on top of it. The context cache also extends a cached
/// shorter prefix. Optional style control token right after the leading EOS: [EOS, STYLE] + encode(left).
public final class NeuralScorer: LmScorer {
    public let tok: SPTokenizer
    public let step: StepModel
    public var styleId: Int?
    private let cacheSize: Int
    private var cache: [String: ([Int], LmState)] = [:]
    private var cacheOrder: [String] = []   // LRU, oldest first
    public private(set) var tokensRun = 0
    public private(set) var calls = 0
    public var lastCtxTokens = 0

    public init(tok: SPTokenizer, step: StepModel, styleId: Int? = nil, cacheSize: Int = 16) {
        self.tok = tok; self.step = step; self.styleId = styleId; self.cacheSize = cacheSize
    }

    private func enc(_ s: String) -> [Int] { [tok.eosId] + (s.isEmpty ? [] : tok.encode(s)) }

    private func clip(_ ctx: [Int]) -> [Int] {
        guard let sid = styleId else { return ctx.count > MAX_CTX ? Array(ctx[(ctx.count - MAX_CTX)...]) : ctx }
        let body = Array(ctx.dropFirst())
        let keep = MAX_CTX - 2
        let tail = body.count > keep ? Array(body[(body.count - keep)...]) : body
        return [tok.eosId, sid] + tail
    }

    private func key(_ t: [Int]) -> String { t.map(String.init).joined(separator: ",") }

    private func touch(_ k: String) {
        if let i = cacheOrder.firstIndex(of: k) { cacheOrder.remove(at: i) }
        cacheOrder.append(k)
    }

    /// State after `toks`: exact cache hit, else extend the longest cached proper prefix, else a fresh run.
    private func prefix(_ toks: [Int]) throws -> LmState {
        let k = key(toks)
        if let e = cache[k] { touch(k); return e.1 }
        var best: ([Int], LmState)? = nil
        for kk in cacheOrder {
            guard let e = cache[kk] else { continue }
            let p = e.0
            if p.count < toks.count && (best == nil || p.count > best!.0.count) && Array(toks[0..<p.count]) == p { best = e }
        }
        let out: LmState
        if let b = best {
            let delta = Array(toks[b.0.count...])
            out = try step.run([delta], pos0: b.0.count, state: b.1, keepState: true).state!
            tokensRun += delta.count
        } else {
            out = try step.run([toks], pos0: 0, state: step.fresh(), keepState: true).state!
            tokensRun += toks.count
        }
        cache[k] = (toks, out); touch(k)
        while cache.count > cacheSize, let old = cacheOrder.first { cacheOrder.removeFirst(); cache[old] = nil }
        return out
    }

    /// Warm the cache with the context of `left` (e.g. right after a word is committed).
    public func warm(_ left: String) throws { _ = try prefix(clip(enc(left))) }

    public func clearCache() { cache.removeAll(); cacheOrder.removeAll() }

    public func score(_ reqs: [LmReq]) throws -> [Double] {
        calls += 1
        struct K { let ctx: [Int]; let tgt: [Int]; let eot: Bool }
        var encCache: [String: [Int]] = [:]
        func encC(_ s: String) -> [Int] { if let e = encCache[s] { return e }; let e = enc(s); encCache[s] = e; return e }
        let keys = reqs.map { r -> K in
            var cont = r.cont
            let eot = cont.hasSuffix(EOT)
            if eot { cont = String(cont.dropLast()) }
            let lt = encC(r.left)
            let ft = enc(r.left + cont)
            var k = 0
            let n = min(lt.count, ft.count - 1)
            while k < n && lt[k] == ft[k] { k += 1 }
            let ctx = clip(Array(ft[0..<k]))
            let tgt0 = Array(ft[k...])
            return K(ctx: ctx, tgt: eot ? tgt0 + [tok.eosId] : tgt0, eot: eot)
        }
        var out = [Double](repeating: 0, count: reqs.count)
        if keys.isEmpty { return out }
        lastCtxTokens = max(lastCtxTokens, keys.map { $0.ctx.count }.max()!)
        let ctxs = keys.map { $0.ctx }
        var p = 0
        while ctxs.allSatisfy({ $0.count > p }) && ctxs.allSatisfy({ $0[p] == ctxs[0][p] }) { p += 1 }
        let pre: LmState = p > 0 ? try prefix(Array(ctxs[0][0..<p])) : step.fresh()
        let rems = keys.map { Array($0.ctx[p...]) + $0.tgt }
        let o = try step.run(rems, pos0: p, state: pre, keepState: false)
        tokensRun += rems.reduce(0) { $0 + $1.count }
        for (b, kk) in keys.enumerated() {
            var s = 0.0
            for q in 0..<kk.tgt.count {
                let j = kk.ctx.count - p + q
                s += j == 0 ? Double(pre.last![kk.tgt[q]]) : Double(o.tokLp[b * o.n + j - 1])
            }
            if !kk.eot { s += Double(o.bnd[b * o.n + rems[b].count - 1]) }
            out[b] = s
        }
        return out
    }
}
