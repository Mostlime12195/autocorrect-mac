import Foundation

/// Decode parameters (manifest "params"): score(c) = spatial(c) + lam * LM(sep + c | left) + bias * [c typed] - pen[kind];
/// the re-check of the previous word uses lam_r and flips when it beats the current choice by > margin.
public struct DecodeParams {
    public var lam: Double
    public var bias: Double
    public var margin: Double?
    public var lamR: Double?
    public var pen: [String: Double]
    public init(lam: Double, bias: Double, margin: Double? = 0, lamR: Double? = nil, pen: [String: Double] = [:]) {
        self.lam = lam; self.bias = bias; self.margin = margin; self.lamR = lamR; self.pen = pen
    }
    public var lamRe: Double { lamR ?? lam }

    public static func from(json o: [String: Any]) -> DecodeParams {
        func d(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        let pen = (o["pen"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
        return DecodeParams(lam: d("lam") ?? 1.25, bias: d("bias") ?? 0, margin: o["margin"] is NSNull ? nil : (d("margin") ?? 0),
                            lamR: d("lam_r"), pen: pen)
    }

    public static let fallback = DecodeParams(lam: 1.25, bias: 0, margin: 0, lamR: 1.25,
                                              pen: ["split": 2, "space": 3, "contr": 1, "contr_rw": 0, "gdrop": 1, "merge": 4])
}

public struct Message {
    public let seps: [String]
    public let words: [Slot]
    public init(seps: [String], words: [Slot]) { self.seps = seps; self.words = words }
}

/// np.argmax (first max) of sp + lam * lm + bias at the typed index - kind penalties
public func choose(_ w: Slot, _ lm: [Double], _ lam: Double, _ bias: Double, _ pen: [String: Double] = [:]) -> (Int, [Double]) {
    var sc = (0..<w.cands.count).map { w.sp[$0] + lam * lm[$0] }
    if w.typedIdx >= 0 { sc[w.typedIdx] += bias }
    for j in 0..<sc.count { let k = w.kind(j); if k != Kind.WORD { sc[j] -= pen[k] ?? 0 } }
    var k = 0
    for i in 1..<max(sc.count, 1) where sc[i] > sc[k] { k = i }
    return (k, sc)
}

/// Port of corrector.decode() for one message (system e: first pass + re-check of the previous word).
public enum Decoder {
    public struct Result { public let outs: [String]; public let idx: [Int] }

    private static func render(_ seps: [String], _ outs: [String?], _ t: Int) -> String {
        var s = ""
        for i in 0..<t { s += seps[i] + outs[i]! }
        return s
    }

    public static func decode(_ msg: Message, _ scorer: LmScorer, _ p: DecodeParams) throws -> Result {
        let T = msg.words.count
        var outs = [String?](repeating: nil, count: T)
        var idx = [Int](repeating: 0, count: T)
        for t in 0..<T {
            let w = msg.words[t]
            let left = render(msg.seps, outs, t)
            let lp = try scorer.score(w.cands.map { LmReq(left, msg.seps[t] + $0) })
            let (k, _) = choose(w, lp, p.lam, p.bias, p.pen)
            idx[t] = k; outs[t] = w.cands[k]
            if let margin = p.margin, t > 0 {
                let wp = msg.words[t - 1]
                let leftp = render(msg.seps, outs, t - 1)
                let nxt = msg.seps[t] + outs[t]!
                let lp2 = try scorer.score(wp.cands.map { LmReq(leftp, msg.seps[t - 1] + $0 + nxt) })
                let (k2, sc2) = choose(wp, lp2, p.lamRe, p.bias, p.pen)
                let cur = idx[t - 1]
                if k2 != cur && sc2[k2] - sc2[cur] > margin { idx[t - 1] = k2; outs[t - 1] = wp.cands[k2] }
            }
        }
        return Result(outs: outs.map { $0! }, idx: idx)
    }
}
