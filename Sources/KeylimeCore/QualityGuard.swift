import Foundation

/// Cheap on-device checks that keep accidents out of what Keylime learns.
public enum QualityGuard {
    /// a was most likely meant as b: one insertion, deletion, substitution or swap of neighbours apart
    public static func looksLikeSlip(_ a: String, of b: String) -> Bool {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x == y || abs(x.count - y.count) > 1 { return false }
        if x.count == y.count {
            let diff = (0..<x.count).filter { x[$0] != y[$0] }
            if diff.count == 1 { return true }
            return diff.count == 2 && diff[1] == diff[0] + 1 && x[diff[0]] == y[diff[1]] && x[diff[1]] == y[diff[0]]
        }
        let (s, l) = x.count < y.count ? (x, y) : (y, x)
        var i = 0
        while i < s.count && s[i] == l[i] { i += 1 }
        return Array(s[i...]) == Array(l[(i + 1)...])
    }

    /// May an undone spelling fix teach the dictionary that `typed` is a word? Not when it looks like a slip of a
    /// common word (the undo was more likely a mistake, or the fix was wrong but so was the typing).
    public static func mayLearn(_ typed: String, undoneFix out: String, outIsCommon: Bool) -> Bool {
        !(outIsCommon && looksLikeSlip(typed, of: out))
    }

    /// An undo followed quickly by retyping the same correction is an accident, not a rejection.
    public static func accidentalUndo(undoneAt: Double, now: Double, wordNow: String?, correction: String, within: Double = 4) -> Bool {
        guard let w = wordNow else { return false }
        return now - undoneAt <= within && w == correction
    }
}
