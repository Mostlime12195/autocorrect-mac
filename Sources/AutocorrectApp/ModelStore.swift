import CryptoKit
import Engine
import Foundation
import KeylimeCore

struct ModelFile {
    let file: String
    let size: Int64
    let sha256: String
}

struct ModelSpec {
    let id: String
    let label: String
    let format: String
    let graph: ModelFile
    let vocab: ModelFile
    let meta: StepMeta
    let params: DecodeParams
    let supportsStyle: Bool
    let styleTokens: [String: Int]
    let styleParams: [String: DecodeParams]
    /// cand-gen v2 kind penalties for the formal style (params.pen_formal: adds caps / punct / comma); params.pen is the
    /// other styles'
    let penFormal: [String: Double]
    /// this model's own mirrors (its Hugging Face repo, then Nest), tried before the manifest's top-level base_urls
    let baseUrls: [String]

    /// a style's control token (style models only; nil = untagged context)
    func styleToken(_ style: String) -> Int? { WritingStyle.token(style, supportsStyle: supportsStyle, tokens: styleTokens) }
    /// a style's decode params (Style.params, as Android ModelSpec.paramsFor)
    func paramsFor(_ style: String) -> DecodeParams {
        WritingStyle.params(style, supportsStyle: supportsStyle, params: params, styleParams: styleParams, penFormal: penFormal)
    }
}

struct Manifest {
    let updated: String
    let baseUrls: [String]
    let defaultId: String
    let models: [ModelSpec]

    func spec(_ id: String?) -> ModelSpec? {
        models.first { $0.id == (id ?? defaultId) } ?? models.first { $0.id == defaultId } ?? models.first
    }

    static func parse(_ data: Data) throws -> Manifest {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ms = o["models"] as? [[String: Any]] else {
            throw StoreError.badManifest
        }
        func file(_ x: Any?) throws -> ModelFile {
            guard let f = x as? [String: Any], let name = f["file"] as? String, let sha = f["sha256"] as? String else { throw StoreError.badManifest }
            return ModelFile(file: name, size: (f["size"] as? NSNumber)?.int64Value ?? 0, sha256: sha.lowercased())
        }
        var models: [ModelSpec] = []
        for m in ms {
            guard let id = m["id"] as? String, let meta = m["meta"] as? [String: Any] else { continue }
            func int(_ k: String) -> Int { (meta[k] as? NSNumber)?.intValue ?? 0 }
            let sm = StepMeta(nKvHeads: int("n_kv_heads"), headDim: int("head_dim"), convKernel: int("conv_kernel"), dModel: int("d_model"),
                              stateNames: meta["state_names"] as? [String] ?? [])
            // graph_tree (one-call tree graph) is ignored until the tree runner is ported; "graph" is the batched step graph
            models.append(ModelSpec(
                id: id, label: m["label"] as? String ?? id, format: m["format"] as? String ?? "ort",
                graph: try file(m["graph"]), vocab: try file(m["vocab"]), meta: sm,
                params: (m["params"] as? [String: Any]).map(DecodeParams.from(json:)) ?? .fallback,
                supportsStyle: m["supports_style"] as? Bool ?? false,
                styleTokens: (m["style_tokens"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.intValue } ?? [:],
                styleParams: (m["style_params"] as? [String: Any])?.compactMapValues { ($0 as? [String: Any]).map(DecodeParams.from(json:)) } ?? [:],
                penFormal: WritingStyle.penFormal(m),
                baseUrls: ModelMirrors.baseUrls(m)))
        }
        if models.isEmpty { throw StoreError.badManifest }
        return Manifest(updated: o["updated"] as? String ?? "", baseUrls: o["base_urls"] as? [String] ?? [(o["base_url"] as? String) ?? ""],
                        defaultId: o["default"] as? String ?? models[0].id, models: models)
    }
}

enum StoreError: Error, CustomStringConvertible {
    case badManifest, download(String), checksum(String)
    var description: String {
        switch self {
        case .badManifest: return "bad model manifest"
        case .download(let s): return "download failed: \(s)"
        case .checksum(let f): return "checksum mismatch for \(f)"
        }
    }
}

/// Model files in ~/Library/Application Support/Autocorrect/models, downloaded from the model's own base URLs
/// (Hugging Face, then Nest), then the manifest's shared ones (ModelMirrors), and checked against the manifest's sha256.
final class ModelStore {
    static let manifestUrls = ModelMirrors.manifestUrls

    let dir: URL
    private(set) var manifest: Manifest?
    private let session: URLSession

    init(dir: URL = Settings.supportDir.appendingPathComponent("models", isDirectory: true)) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
        if let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) { manifest = try? Manifest.parse(d) }
    }

    func url(_ f: ModelFile) -> URL { dir.appendingPathComponent(f.file) }

    private func okMarker(_ f: ModelFile) -> URL { dir.appendingPathComponent(".\(f.file).sha256") }

    /// present and verified at download time (sha marker matches the manifest)
    func isInstalled(_ f: ModelFile) -> Bool {
        guard FileManager.default.fileExists(atPath: url(f).path),
              let m = try? String(contentsOf: okMarker(f), encoding: .utf8) else { return false }
        return m.trimmingCharacters(in: .whitespacesAndNewlines) == f.sha256
    }

    func isInstalled(_ s: ModelSpec) -> Bool { isInstalled(s.graph) && isInstalled(s.vocab) }

    /// Fetch the manifest (Nest, then GitHub); keeps the cached one when both fail.
    func refreshManifest() async -> Manifest? {
        for u in Self.manifestUrls {
            guard let url = URL(string: u) else { continue }
            do {
                let (data, resp) = try await session.data(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let m = try Manifest.parse(data)
                try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
                manifest = m
                return m
            } catch { continue }
        }
        return manifest
    }

    /// Download + verify every missing file of a model. progress: 0...1 over both files.
    func install(_ s: ModelSpec, progress: @escaping (Double) -> Void) async throws {
        let files = [s.vocab, s.graph].filter { !isInstalled($0) }
        let total = Double(files.reduce(Int64(0)) { $0 + max($1.size, 1) })
        var done = 0.0
        for f in files {
            var lastErr: Error = StoreError.download("no mirror")
            var ok = false
            for base in ModelMirrors.order(model: s.baseUrls, top: manifest?.baseUrls ?? []) where !ok {
                guard let src = URL(string: base + f.file) else { continue }
                do {
                    try await fetch(src, f) { frac in progress((done + frac * Double(max(f.size, 1))) / max(total, 1)) }
                    ok = true
                } catch { lastErr = error }
            }
            if !ok { throw lastErr }
            done += Double(max(f.size, 1))
            progress(done / max(total, 1))
        }
    }

    private func fetch(_ src: URL, _ f: ModelFile, progress: @escaping (Double) -> Void) async throws {
        let (tmp, resp) = try await download(src, progress: progress)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let code = (resp as? HTTPURLResponse)?.statusCode, code == 200 else {
            throw StoreError.download("\(src.host ?? "") HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let sha = try Self.sha256(tmp)
        guard sha == f.sha256 else { throw StoreError.checksum(f.file) }
        let dst = url(f)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        try sha.write(to: okMarker(f), atomically: true, encoding: .utf8)
    }

    private func download(_ src: URL, progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            var obs: NSKeyValueObservation?
            let task = session.downloadTask(with: src) { loc, resp, err in
                obs?.invalidate()
                if let err = err { cont.resume(throwing: err); return }
                guard let loc = loc, let resp = resp else { cont.resume(throwing: StoreError.download("no data")); return }
                // the temp file is deleted when this handler returns: move it first
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent("ac-\(UUID().uuidString)")
                do { try FileManager.default.moveItem(at: loc, to: keep); cont.resume(returning: (keep, resp)) } catch { cont.resume(throwing: error) }
            }
            obs = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }

    static func sha256(_ file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = h.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
