import XCTest
@testable import Engine

/// Long left context on the real m2s graph: the highest position the graph accepts, and what a word costs at 64 / 256 /
/// 1024 tokens of context when typing through a long text (the state cache extends a shared prefix between words).
final class LongContextTests: XCTestCase {
    static let passage = """
    I went to the market this morning because we were out of almost everything, and the fridge had started to look a \
    little sad. The walk there is nice when it isn't raining, so I took the long way past the river and the old mill. \
    At the market the usual stalls were open: the baker with the sourdough everyone queues for, the woman who sells \
    honey from her own hives, and the fruit stand that always has something I have never heard of. I bought bread, \
    a jar of honey, some apples, a bag of oranges and a strange spiky fruit the seller promised was sweet. On the way \
    home I stopped at the cafe on the corner for a coffee and read the paper for a while, which I almost never get to do \
    during the week. By the time I got back it was nearly noon, and I still had to answer a pile of messages from work. 
    """

    func testPositionLimitAndCostPerWord() throws {
        let path = try Fixtures.modelPath("m2s.step.int4m.ort")
        let ref = Fixtures.json("pipeline_m2s.json") as! [String: Any]
        let m = ref["meta"] as! [String: Any]
        let meta = StepMeta(nKvHeads: (m["n_kv_heads"] as! NSNumber).intValue, headDim: (m["head_dim"] as! NSNumber).intValue,
                            convKernel: (m["conv_kernel"] as! NSNumber).intValue, dModel: (m["d_model"] as! NSNumber).intValue,
                            stateNames: m["state_names"] as! [String])
        let step = try StepModel.open(path: path, meta: meta, threads: 4)
        defer { step.close() }
        let mp = step.maxPosition()
        print("m2s graph: highest accepted position \(mp)")
        XCTAssertGreaterThanOrEqual(mp, 127)

        // ~7000 characters of running text; the last 60 words are "typed" with a transposition typo each
        let text = String(repeating: Self.passage, count: 6)
        let cs = Array(text)
        let words = segRanges(text).filter { $0.1 - $0.0 >= 4 }.suffix(60)
        let corr = Corrector(gen: Fixtures.gen, gen2: Fixtures.gen2)
        let p = DecodeParams(lam: 1.25, bias: 0, margin: 0, lamR: 1.25)
        let style = (ref["style_id"] as! NSNumber).intValue
        for n in [64, 256, 1024] {
            let sc = NeuralScorer(tok: Fixtures.tokM2, step: step, styleId: style)
            sc.maxPos = mp
            sc.maxCtx = n
            let chars = max(400, n * 5)
            var ms: [Double] = []
            var fixed = 0
            for (a, b) in words {
                var w = Array(cs[a..<b])
                w.swapAt(1, 2)
                let typed = String(w)
                let start = TypingCore.contextStart(a, chars: chars)
                let (left, sep) = TypingCore.splitLeft(String(cs[start..<a]))
                let t0 = Date()
                let r = try corr.correctWord(WordInput(typed: typed, left: left, sep: sep), scorer: sc, params: p, prev: nil)
                ms.append(Date().timeIntervalSince(t0) * 1000)
                if r.out.lowercased() == String(cs[a..<b]).lowercased() { fixed += 1 }
            }
            let s = ms.sorted()
            print(String(format: "context %4d tokens (effective %d, %d chars): %.1f ms/word avg, p50 %.1f, p95 %.1f, max %.1f; %d/%d typos fixed; %d tokens run",
                         n, sc.effectiveMaxCtx, chars, ms.reduce(0, +) / Double(ms.count), s[s.count / 2], s[Int(Double(s.count) * 0.95) - 1],
                         s.last!, fixed, ms.count, sc.tokensRun))
        }
    }
}
