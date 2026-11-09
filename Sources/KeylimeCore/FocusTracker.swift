import Foundation

/// How a remembered focused element is doing when the focus query itself fails.
public enum Liveness: Equatable {
    /// it says it's focused (AXFocused = true)
    case focused
    /// it still answers (text / selection readable), focus unknown
    case answers
    /// gone, or says it's not focused any more
    case dead
}

/// Which element is being typed in, tolerant of focus queries that fail now and then (Electron / Chromium answer
/// "no value" between keystrokes). A failed query never drops the field by itself: the last good element is kept
/// while it still answers, and only given up when it's dead, or when it can't confirm it's focused for `grace` seconds
/// of failures in a row. Generic over the element so it can be tested without Accessibility.
public final class FocusTracker<E> {
    public enum Decision: Equatable {
        /// the query found the element we have
        case same
        /// a different element is focused (or the first one)
        case changed
        /// the query failed: keep using the element we have
        case holding
        /// the query failed and the element we had is gone
        case lost
        /// the query failed and we had nothing
        case none
    }

    public let grace: Double
    public private(set) var current: E?
    /// failed queries in a row / since start
    public private(set) var failuresInRow = 0
    public private(set) var failures = 0
    /// when the focus query last worked
    public private(set) var lastGood: Double?
    private var failingSince: Double?
    private let same: (E, E) -> Bool

    public init(grace: Double = 3, same: @escaping (E, E) -> Bool) {
        self.grace = grace
        self.same = same
    }

    public func observe(_ found: E?, now: Double, alive: (E) -> Liveness) -> Decision {
        if let e = found {
            failuresInRow = 0
            failingSince = nil
            lastGood = now
            if let c = current, same(c, e) { return .same }
            current = e
            return .changed
        }
        failuresInRow += 1
        failures += 1
        if failingSince == nil { failingSince = now }
        guard let c = current else { return .none }
        switch alive(c) {
        case .focused:
            return .holding
        case .answers where now - failingSince! < grace:
            return .holding
        default:
            current = nil
            return .lost
        }
    }

    /// app switch: start over
    public func reset() {
        current = nil
        failuresInRow = 0
        failingSince = nil
    }
}
