import Foundation

/// How much work the checks cost, for the usage meter: timings of word-end corrections and pause re-checks, cancelled
/// passes, and the process's CPU time, over the last minute. Thread-safe; time is passed in (seconds).
public final class PerfMeter {
    public struct Stat: Equatable {
        public let count: Int
        public let avgMs: Double
        public let p95Ms: Double
    }

    public struct Summary {
        public let wordEnds: Stat
        public let passes: Stat
        public let cancelled: Int
        /// percent of one core over the last minute (nil until two samples)
        public let cpuPercent: Double?
        /// nil = keeping up, else why not
        public let behind: String?
        public let energy: String
    }

    public enum Kind { case wordEnd, pass }

    private let lock = NSLock()
    private var samples: [(at: Double, ms: Double, kind: Kind)] = []
    private var cancels: [Double] = []
    private var cpu: [(at: Double, sec: Double)] = []
    public static let WINDOW = 60.0

    public init() {}

    public func record(_ kind: Kind, ms: Double, at: Double) {
        lock.lock(); defer { lock.unlock() }
        samples.append((at, ms, kind))
        trim(at)
    }

    public func cancelled(at: Double) {
        lock.lock(); defer { lock.unlock() }
        cancels.append(at)
        trim(at)
    }

    /// the process's total CPU seconds so far (user + system)
    public func cpuSample(seconds: Double, at: Double) {
        lock.lock(); defer { lock.unlock() }
        cpu.append((at, seconds))
        trim(at)
    }

    private func trim(_ now: Double) {
        let cut = now - Self.WINDOW
        samples.removeAll { $0.at < cut }
        cancels.removeAll { $0 < cut }
        // keep one CPU sample older than the window, so the window is fully covered
        while cpu.count > 2 && cpu[1].at < cut { cpu.removeFirst() }
    }

    static func stat(_ ms: [Double]) -> Stat {
        guard !ms.isEmpty else { return Stat(count: 0, avgMs: 0, p95Ms: 0) }
        let s = ms.sorted()
        let p95 = s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
        return Stat(count: ms.count, avgMs: ms.reduce(0, +) / Double(ms.count), p95Ms: p95)
    }

    /// pauseSecs: the re-check pause setting; backlog: engine jobs waiting right now
    public func summary(now: Double, pauseSecs: Double, backlog: Int) -> Summary {
        lock.lock(); defer { lock.unlock() }
        trim(now)
        let words = Self.stat(samples.filter { $0.kind == .wordEnd }.map(\.ms))
        let passes = Self.stat(samples.filter { $0.kind == .pass }.map(\.ms))
        var pct: Double? = nil
        if let a = cpu.first, let b = cpu.last, b.at - a.at >= 1 { pct = max(0, (b.sec - a.sec) / (b.at - a.at) * 100) }
        var behind: String? = nil
        if backlog >= 3 {
            behind = "\(backlog) checks waiting in line"
        } else if passes.count >= 3 && passes.avgMs > pauseSecs * 1000 {
            behind = String(format: "a re-check takes %.0f ms on average, longer than the %.1f s pause", passes.avgMs, pauseSecs)
        } else if words.count >= 5 && words.p95Ms > 400 {
            behind = String(format: "slow word ends (p95 %.0f ms)", words.p95Ms)
        }
        let energy: String
        switch pct ?? 0 {
        case ..<3: energy = "negligible"
        case ..<10: energy = "light (like an idle browser tab)"
        case ..<25: energy = "moderate: noticeable on battery"
        default: energy = "heavy: will cost real battery"
        }
        return Summary(wordEnds: words, passes: passes, cancelled: cancels.count, cpuPercent: pct, behind: behind, energy: energy)
    }
}
