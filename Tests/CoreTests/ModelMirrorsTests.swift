import XCTest
@testable import KeylimeCore

final class ModelMirrorsTests: XCTestCase {
    let nest = "https://autocorrect.mostlime.hackclub.app/autocorrect-android/"
    let hf = "https://huggingface.co/MostLime/keylime-m2/resolve/main/"

    func testManifestFromNestFirst() {
        XCTAssertEqual(ModelMirrors.manifestUrls, [
            nest + "manifest.json",
            "https://github.com/Mostlime12195/keylime-models/releases/download/models-v1/manifest.json",
        ])
        XCTAssertEqual(ModelMirrors.fallbackBases, [nest])
    }

    func testPerModelMirrorsComeFirst() throws {
        let json = #"{"base_urls": ["\#(nest)"], "models": [{"id": "m2s_int4", "base_urls": ["\#(hf)", "\#(nest)"]}, {"id": "old"}]}"#
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let models = try XCTUnwrap(o["models"] as? [[String: Any]])
        let top = o["base_urls"] as? [String] ?? []
        XCTAssertEqual(ModelMirrors.baseUrls(models[0]), [hf, nest])
        XCTAssertEqual(ModelMirrors.order(model: ModelMirrors.baseUrls(models[0]), top: top), [hf, nest])
        // a model without its own list uses the top-level ones, then the fallback
        XCTAssertEqual(ModelMirrors.baseUrls(models[1]), [])
        XCTAssertEqual(ModelMirrors.order(model: [], top: ["https://top/"]), ["https://top/", nest])
        XCTAssertEqual(ModelMirrors.order(model: [], top: []), [nest])
    }

    func testNoGitHubModelMirrors() {
        for u in ModelMirrors.order(model: [hf], top: [nest]) { XCTAssertFalse(u.contains("github.com"), u) }
    }

    /// With AC_MODEL_DIR set (CI), the manifest fetch_models.sh downloaded must give every model HF first, then Nest.
    func testFetchedManifestUsesHuggingFace() throws {
        guard let dir = ProcessInfo.processInfo.environment["AC_MODEL_DIR"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("manifest.json")) else {
            throw XCTSkip("no AC_MODEL_DIR manifest")
        }
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(o["models"] as? [[String: Any]])
        let top = o["base_urls"] as? [String] ?? []
        XCTAssertFalse(models.isEmpty)
        for m in models {
            let order = ModelMirrors.order(model: ModelMirrors.baseUrls(m), top: top)
            XCTAssertTrue(order.first?.hasPrefix("https://huggingface.co/MostLime/keylime-m") ?? false, "\(m["id"] ?? "?"): \(order)")
            XCTAssertTrue(order.contains(nest))
            for u in order { XCTAssertFalse(u.contains("github.com"), u) }
        }
    }
}
