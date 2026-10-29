import CoreGraphics
import Foundation

/// Typing into the focused app.
///
/// Every event carries `marker` so the tap lets it through untouched, and is
/// made from a private event source with explicit flags, so the Shift the user
/// is still holding for Shift+Backspace does not leak into it.
enum Inject {
    static let marker: Int64 = 0x5249_4754 // "RIGT"
    private static let source = CGEventSource(stateID: .privateState)

    static func backspaces(_ n: Int) {
        for _ in 0..<n { key(Keys.delete) }
    }

    /// Type `text` as Unicode, whatever the input source. A line break is
    /// pressed as Return (a snippet of several lines).
    static func type(_ text: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            if i > 0 { key(Keys.returnKey) }
            typeLine(String(line))
        }
    }

    private static func typeLine(_ text: String) {
        let units = Array(text.utf16)
        // Some apps read at most 20 UTF-16 units from one event.
        var i = 0
        while i < units.count {
            var end = min(i + 20, units.count)
            // Do not split a surrogate pair.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[i..<end])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                post(e)
            }
            i = end
        }
    }

    /// A boundary key (space, Return, Tab) by its Unicode value.
    static func boundary(_ scalar: UInt32) {
        switch scalar {
        case 0x20: key(Keys.space)
        case 0x0D, 0x0A: key(Keys.returnKey)
        case 0x09: key(Keys.tab)
        default: break
        }
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            post(e)
        }
    }

    private static func post(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
    }
}
