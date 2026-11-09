import Carbon
import Foundation

/// Physical key positions (ANSI virtual key codes) and the active layout's letter -> key mapping, so the spatial model
/// sees where each letter really sits (QWERTZ, AZERTY, Dvorak, Colemak, ...).
enum KeyLayout {
    /// virtual key code -> (row, column) on the three letter rows
    static let physical: [CGKeyCode: (Int, Int)] = {
        let rows: [[CGKeyCode]] = [
            [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30],   // q w e r t y u i o p [ ]
            [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],             // a s d f g h j k l ; '
            [6, 7, 8, 9, 11, 45, 46, 43, 47, 44],               // z x c v b n m , . /
        ]
        var m: [CGKeyCode: (Int, Int)] = [:]
        for (r, row) in rows.enumerated() { for (c, k) in row.enumerated() { m[k] = (r, c) } }
        return m
    }()

    struct Info {
        /// letter -> centre in model units
        let centers: [Character: (Double, Double)]
        /// letter -> key code (for synthesized key events)
        let keyCodes: [Character: CGKeyCode]
        /// an input method (CJK etc.) is active: keystrokes aren't text, so no corrections
        let isInputMethod: Bool
        let name: String
    }

    static func current() -> Info {
        var centers: [Character: (Double, Double)] = [:]
        var codes: [Character: CGKeyCode] = [:]
        var ime = false
        var name = "?"
        if let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
            if let t = TISGetInputSourceProperty(cur, kTISPropertyInputSourceType) {
                let type = Unmanaged<CFString>.fromOpaque(t).takeUnretainedValue() as String
                ime = type == (kTISTypeKeyboardInputMode as String)
            }
            if let n = TISGetInputSourceProperty(cur, kTISPropertyLocalizedName) {
                name = Unmanaged<CFString>.fromOpaque(n).takeUnretainedValue() as String
            }
        }
        if let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                    for (code, rc) in physical {
                        var dead: UInt32 = 0
                        var len = 0
                        var chars = [UniChar](repeating: 0, count: 4)
                        let st = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                        guard st == noErr, len == 1, let s = String(utf16CodeUnits: chars, count: 1).lowercased().first,
                              s.isASCII, s.isLetter else { continue }
                        codes[s] = code
                        centers[s] = ([0.0, 0.5, 1.5][rc.0] + Double(rc.1) + 0.5, Double(rc.0) * 1.4 + 0.7)
                    }
                }
            }
        }
        return Info(centers: centers, keyCodes: codes, isInputMethod: ime, name: name)
    }
}
