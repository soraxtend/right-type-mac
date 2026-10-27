import Carbon
import CoreGraphics

/// The US-QWERTY character each physical key types, without and with Shift.
/// The core names every key this way, whatever input source is active.
enum Keys {
    static let delete: CGKeyCode = 51
    static let space: CGKeyCode = 49
    static let returnKey: CGKeyCode = 36
    static let enter: CGKeyCode = 76
    static let tab: CGKeyCode = 48
    static let c: CGKeyCode = 8
    static let v: CGKeyCode = 9

    private static let table: [CGKeyCode: (Character, Character)] = [
        50: ("`", "~"), 18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"),
        23: ("5", "%"), 22: ("6", "^"), 26: ("7", "&"), 28: ("8", "*"), 25: ("9", "("),
        29: ("0", ")"), 27: ("-", "_"), 24: ("=", "+"),
        12: ("q", "Q"), 13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"), 17: ("t", "T"),
        16: ("y", "Y"), 32: ("u", "U"), 34: ("i", "I"), 31: ("o", "O"), 35: ("p", "P"),
        33: ("[", "{"), 30: ("]", "}"), 42: ("\\", "|"),
        0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 5: ("g", "G"),
        4: ("h", "H"), 38: ("j", "J"), 40: ("k", "K"), 37: ("l", "L"), 41: (";", ":"),
        39: ("'", "\""),
        6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"), 11: ("b", "B"),
        45: ("n", "N"), 46: ("m", "M"), 43: (",", "<"), 47: (".", ">"), 44: ("/", "?"),
    ]

    /// The key's US-QWERTY character as a Unicode scalar, or nil for a key
    /// that types no text (arrows, function keys, the keypad).
    static func qwerty(_ code: CGKeyCode, shift: Bool) -> UInt32? {
        guard let pair = table[code] else { return nil }
        return (shift ? pair.1 : pair.0).unicodeScalars.first?.value
    }

    /// Every text key with and without Shift, with its US-QWERTY character.
    static var all: [(code: CGKeyCode, shift: Bool, qwerty: UInt32)] {
        table.flatMap { code, pair in
            [(code, false, pair.0.unicodeScalars.first!.value),
             (code, true, pair.1.unicodeScalars.first!.value)]
        }
    }
}
