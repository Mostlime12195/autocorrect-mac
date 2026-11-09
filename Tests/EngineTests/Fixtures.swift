import Foundation
import XCTest
@testable import Engine

enum Fixtures {
    static func url(_ name: String) -> URL {
        guard let u = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            fatalError("missing fixture \(name)")
        }
        return u
    }

    static func data(_ name: String) -> Data { try! Data(contentsOf: url(name)) }

    static func json(_ name: String) -> Any { try! JSONSerialization.jsonObject(with: data(name)) }

    /// the lexicon the Python reference fixtures were made with (the app ships the cleaned one)
    static let lexicon = Lexicon(tsv: data("lexicon_ref.tsv"))
    static let gen = CandidateGenerator(lex: lexicon, sp: SpatialModel(sigma: 0.3))
    static let gen2 = CandidateGeneratorV2(gen: gen)
    static let tokM1 = try! SPTokenizer.fromJSON(data("vocab.json"))
    static let tokM2 = try! SPTokenizer.fromJSON(data("vocab_m2.json"))

    static var pipelineRef: [String: Any] { json("pipeline_ref.json") as! [String: Any] }

    /// the 50 reference messages with the Python key-centre candidate slots
    static func messages(_ ref: [String: Any]) -> [Message] {
        let texts = ref["texts"] as! [String]
        let cands = ref["cands"] as! [[[String: Any]]]
        return texts.enumerated().map { m, t in
            let (seps, words) = segment(t)
            return Message(seps: seps, words: words.enumerated().map { i, w in
                let e = cands[m][i]
                return Slot(typed: w, cands: e["cands"] as! [String], sp: (e["sp"] as! [NSNumber]).map { $0.doubleValue },
                            typedIdx: (e["typed_idx"] as! NSNumber).intValue)
            })
        }
    }

    /// model files for the ORT tests: AC_MODEL_DIR (CI downloads them). AC_REQUIRE_MODELS=1 turns a missing file into a failure.
    static func modelPath(_ file: String) throws -> String {
        let dir = ProcessInfo.processInfo.environment["AC_MODEL_DIR"] ?? ""
        let p = (dir as NSString).appendingPathComponent(file)
        if dir.isEmpty || !FileManager.default.fileExists(atPath: p) {
            if ProcessInfo.processInfo.environment["AC_REQUIRE_MODELS"] == "1" { XCTFail("missing model \(p)") }
            throw XCTSkip("no \(file) (set AC_MODEL_DIR)")
        }
        return p
    }
}
