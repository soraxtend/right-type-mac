import Carbon
import Foundation

/// The active keyboard input source, as far as RightType is concerned.
///
/// A source counts as Thai or English by what its keys type, not by its name,
/// so custom layouts (Ukelele ones, say) work as long as their keys are
/// Kedmanee's or US QWERTY's. Anything else (Dvorak, an IME) is left alone.
enum InputSources {
    /// RT_LAYOUT_* of the active source, or nil when it is one RightType stays out of.
    private(set) static var current: Int32? = nil
    /// The sources last used for each language, to switch back to.
    private static var lastThai: String?
    private static var lastEnglish: String?
    /// Until when a source change is our own doing.
    private static var ownSwitchUntil = Date.distantPast
    private static var kinds: [String: Int32] = [:]

    /// Called when the source changes; `ours` is true for switches RightType made.
    static var onChange: ((_ ours: Bool) -> Void)?

    static func start() {
        refresh()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in
            refresh()
            onChange?(Date() < ownSwitchUntil)
        }
    }

    static func refresh() {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        current = kind(of: source)
        guard let id = sourceID(source) else { return }
        if current == RT_LAYOUT_THAI { lastThai = id }
        if current == RT_LAYOUT_ENGLISH { lastEnglish = id }
    }

    /// Switch to Thai or English, if such a source is enabled.
    static func select(_ layout: Int32) {
        guard layout != RT_LAYOUT_NONE, layout != current else { return }
        let sources = enabled()
        let remembered = layout == RT_LAYOUT_THAI ? lastThai : lastEnglish
        let target = sources.first { sourceID($0) == remembered }
            ?? sources.first { kind(of: $0) == layout }
        guard let target else { return }
        ownSwitchUntil = Date().addingTimeInterval(0.5)
        TISSelectInputSource(target)
        current = layout
    }

    /// Whether a Thai source RightType understands is enabled at all.
    static var thaiEnabled: Bool {
        enabled().contains { kind(of: $0) == RT_LAYOUT_THAI }
    }

    /// The enabled keyboard layouts by name, as RightType reads them.
    static var enabledSummary: (thai: [String], english: [String], other: [String]) {
        var result: (thai: [String], english: [String], other: [String]) = ([], [], [])
        for source in enabled() {
            guard let p = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { continue }
            let name = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            switch kind(of: source) {
            case RT_LAYOUT_THAI: result.thai.append(name)
            case RT_LAYOUT_ENGLISH: result.english.append(name)
            default: result.other.append(name)
            }
        }
        return result
    }

    private static func enabled() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceIsSelectCapable as String: true,
                      kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        return TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    /// Thai, English or neither, judged by what the source types on each key.
    private static func kind(of source: TISInputSource) -> Int32? {
        let id = sourceID(source) ?? ""
        if let known = kinds[id] { return known == RT_LAYOUT_NONE ? nil : known }
        var result = RT_LAYOUT_NONE
        if let p = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data
            var english = 0, thai = 0, total = 0
            data.withUnsafeBytes { raw in
                guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
                for key in Keys.all {
                    guard let typed = translate(layout, key.code, shift: key.shift) else { continue }
                    total += 1
                    if typed == key.qwerty { english += 1 }
                    if typed == rt_kedmanee(key.qwerty) { thai += 1 }
                }
            }
            // Allow a few keys to differ: macOS's own Thai layout swaps two
            // symbols against Kedmanee, and other English layouts move a few.
            if total > 0 {
                if Double(thai) >= Double(total) * 0.9 { result = RT_LAYOUT_THAI }
                else if Double(english) >= Double(total) * 0.95 { result = RT_LAYOUT_ENGLISH }
            }
        }
        kinds[id] = result
        return result == RT_LAYOUT_NONE ? nil : result
    }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, _ code: CGKeyCode, shift: Bool) -> UInt32? {
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let modifiers = shift ? UInt32(shiftKey >> 8) : 0
        let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        guard status == noErr, length == 1 else { return nil }
        return UInt32(chars[0])
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
}
