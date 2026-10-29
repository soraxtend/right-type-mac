import AppKit
import CoreGraphics

/// Runs a macro snippet's steps (`righttype::macros`), as the core encodes
/// them: `T<text>`, `K<Windows virtual keys>`, `W<ms>`, `C` (the clipboard).
/// Keys are named as on Windows; Command stands where the Windows key is,
/// Option where Alt is.
enum Macro {
    private static let queue = DispatchQueue(label: "righttype.macro")

    static func run(_ encoded: String) {
        let steps = encoded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Off the tap: steps wait, and the app needs time to take each key.
        queue.async {
            for step in steps {
                guard let kind = step.first else { continue }
                let arg = String(step.dropFirst())
                switch kind {
                case "T": Inject.type(arg)
                case "K": press(arg.split(separator: ",").compactMap { UInt16($0) })
                case "W": Thread.sleep(forTimeInterval: Double(Int(arg) ?? 0) / 1000)
                case "C":
                    let text = DispatchQueue.main.sync { NSPasteboard.general.string(forType: .string) }
                    if let text { Inject.type(text) }
                default: break
                }
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
    }

    /// Modifiers first, then the key (`shortcuts::virtual_keys`).
    private static func press(_ vks: [UInt16]) {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for vk in vks {
            switch vk {
            case 0x11: flags.insert(.maskControl)
            case 0x10: flags.insert(.maskShift)
            case 0x12: flags.insert(.maskAlternate)
            case 0x5B: flags.insert(.maskCommand)
            default: key = keyCode(vk)
            }
        }
        if let key { Inject.key(key, flags: flags) }
    }

    private static let named: [UInt16: CGKeyCode] = [
        0x20: 49, 0x0D: 36, 0x08: 51, 0x09: 48, 0x1B: 53, 0x2E: 117, 0x2D: 114,
        0x24: 115, 0x23: 119, 0x21: 116, 0x22: 121, 0x25: 123, 0x26: 126, 0x27: 124, 0x28: 125,
        0x70: 122, 0x71: 120, 0x72: 99, 0x73: 118, 0x74: 96, 0x75: 97, 0x76: 98, 0x77: 100,
        0x78: 101, 0x79: 109, 0x7A: 103, 0x7B: 111,
    ]

    private static let symbols: [UInt16: Character] = [
        0xBA: ";", 0xBB: "=", 0xBC: ",", 0xBD: "-", 0xBE: ".", 0xBF: "/", 0xC0: "`",
        0xDB: "[", 0xDC: "\\", 0xDD: "]", 0xDE: "'",
    ]

    private static func keyCode(_ vk: UInt16) -> CGKeyCode? {
        if let code = named[vk] { return code }
        let char: Character?
        switch vk {
        case 0x41...0x5A: char = Unicode.Scalar(vk + 0x20).map(Character.init)
        case 0x30...0x39: char = Unicode.Scalar(vk).map(Character.init)
        default: char = symbols[vk]
        }
        guard let value = char?.unicodeScalars.first?.value else { return nil }
        return Keys.all.first { $0.qwerty == value && !$0.shift }?.code
    }
}
