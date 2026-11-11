import Foundation

/// Words with one right spelling that are fixed the same way every time, without asking the model (standard and formal
/// styles; casual keeps text as typed). The user can still undo one: an undone edit is left alone while its penalty lasts.
///
///  - the pronoun I: i, i'm, i'll, i'd, i've -> I, I'm, I'll, I'd, I've
///  - a missing apostrophe, only where the apostrophe-less form isn't an English word ("dont" -> "don't"). Deliberately
///    NOT in the table because they are words: wont, cant, its, lets, id, ill, hell, shell, well, were, wed, shed.
///    Left out as ambiguous: youd, theyd, yall, whos (whose).
///
/// The case of the first letter is kept ("Dont" -> "Don't"); I-words are always capital ("im" -> "I'm"). ALLCAPS and
/// mixed case are left alone. A curly apostrophe typed in an i-word is kept ("i’m" -> "I’m").
///
/// CONTRACTIONS is the shared table: one "typed fixed" pair per line, lowercase. Android copies it verbatim.
public enum FixedWords {
    public static let CONTRACTIONS = """
        im i'm
        ive i've
        dont don't
        doesnt doesn't
        didnt didn't
        isnt isn't
        wasnt wasn't
        arent aren't
        werent weren't
        havent haven't
        hasnt hasn't
        hadnt hadn't
        couldnt couldn't
        wouldnt wouldn't
        shouldnt shouldn't
        mustnt mustn't
        aint ain't
        youre you're
        youve you've
        youll you'll
        theyre they're
        theyve they've
        theyll they'll
        weve we've
        wouldve would've
        couldve could've
        shouldve should've
        thats that's
        whats what's
        theres there's
        heres here's
        wheres where's
        """

    /// typed (lowercase) -> fixed (lowercase)
    public static let table: [String: String] = {
        var m: [String: String] = [:]
        for line in CONTRACTIONS.split(separator: "\n") {
            let p = line.split(separator: " ")
            if p.count == 2 { m[String(p[0])] = String(p[1]) }
        }
        return m
    }()

    /// the standalone pronoun and its contractions (straight apostrophe; a curly one is matched too)
    public static let I_WORDS: Set<String> = ["i", "i'm", "i'll", "i'd", "i've"]

    /// The fixed form of a typed word, or nil when it isn't one of these (or is already right).
    public static func fix(_ typed: String) -> String? {
        guard let f = typed.first, f.isLetter, typed.dropFirst().allSatisfy({ !$0.isUppercase }) else { return nil }
        let curly = typed.contains("\u{2019}")
        let low = typed.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        var out: String
        if I_WORDS.contains(low) {
            out = "I" + low.dropFirst()
        } else if let c = table[low] {
            out = c.hasPrefix("i'") ? "I" + c.dropFirst() : (f.isUppercase ? c.prefix(1).uppercased() + c.dropFirst() : c)
        } else {
            return nil
        }
        if curly { out = out.replacingOccurrences(of: "'", with: "\u{2019}") }
        return out == typed ? nil : out
    }
}
