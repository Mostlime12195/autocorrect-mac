import CryptoKit
import Foundation

/// mac-latest.json on the update server.
public struct LatestInfo: Decodable, Equatable {
    public let version: String
    public let url: String
    public let sha256: String
    public let size: Int
    public let notes: String?
}

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case badManifest(String)
    case sizeMismatch(Int, Int)
    case shaMismatch(String, String)

    public var description: String {
        switch self {
        case .badManifest(let s): return "bad update manifest: \(s)"
        case .sizeMismatch(let want, let got): return "download is \(got) bytes, expected \(want)"
        case .shaMismatch(let want, let got): return "download sha256 \(got.prefix(12))…, expected \(want.prefix(12))…"
        }
    }
}

/// The updater's pure parts: manifest parsing, version order, download verification.
public enum UpdateCore {
    public static func parse(_ data: Data) throws -> LatestInfo {
        let l: LatestInfo
        do { l = try JSONDecoder().decode(LatestInfo.self, from: data) } catch { throw UpdateError.badManifest("\(error)") }
        guard version(l.version) != nil else { throw UpdateError.badManifest("version \(l.version)") }
        guard let u = URL(string: l.url), u.scheme == "https", u.host != nil else { throw UpdateError.badManifest("url \(l.url)") }
        guard l.sha256.count == 64, l.sha256.allSatisfy({ $0.isHexDigit }) else { throw UpdateError.badManifest("sha256") }
        guard l.size > 0 else { throw UpdateError.badManifest("size") }
        return l
    }

    /// "1.2.3" -> [1, 2, 3]; nil unless it's dot-separated numbers
    public static func version(_ s: String) -> [Int]? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !p.isEmpty, p.count <= 4 else { return nil }
        var out: [Int] = []
        for x in p { guard let n = Int(x), n >= 0, x.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }; out.append(n) }
        return out
    }

    public static func newer(_ a: String, than b: String) -> Bool {
        guard let x = version(a) else { return false }
        let y = version(b) ?? [0]
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    public static func sha256Hex(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// the downloaded file is exactly the one the manifest describes
    public static func verify(_ file: URL, _ l: LatestInfo) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? -1
        guard size == l.size else { throw UpdateError.sizeMismatch(l.size, size) }
        let sha = try sha256Hex(of: file)
        guard sha == l.sha256.lowercased() else { throw UpdateError.shaMismatch(l.sha256.lowercased(), sha) }
    }
}
