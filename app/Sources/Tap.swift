import AppKit
import Carbon
import CoreGraphics

/// What RightType does while you type (`RT_MODE_*`).
enum Mode: Int {
    case off = 0
    /// Fixes only when asked (Shift+Backspace).
    case manual = 1
    /// Also fixes a word on its own when it ends (Space, Return, Tab).
    case semiAuto = 2
    /// Also fixes Thai typed on the English layout while it is typed, as the
    /// Windows version does: Thai has no spaces to wait for.
    case auto = 3
    /// Shows the fix by the caret; Tab takes it. Never changes text by itself.
    case suggest = 4

    var name: String {
        switch self {
        case .off: return "ปิด"
        case .manual: return "กดแก้เอง"
        case .semiAuto: return "แก้เมื่อจบคำ"
        case .auto: return "อัตโนมัติ"
        case .suggest: return "แนะนำ"
        }
    }

    /// What the mode does, in one line (the settings page and the menu).
    var detail: String {
        switch self {
        case .off: return "RightType ไม่ทำอะไร"
        case .manual: return "ไม่แก้ข้อความเอง กด ⇧⌫ เพื่อแก้คำล่าสุด"
        case .semiAuto: return "แก้คำที่พิมพ์ผิดภาษาเมื่อเคาะวรรคหรือ Enter แล้วสลับคีย์บอร์ดให้"
        case .auto: return "แก้และสลับภาษาให้ทันทีระหว่างพิมพ์ ไม่ต้องรอวรรค ⇧⌫ ย้อนได้"
        case .suggest: return "แสดงคำที่แก้แล้วข้างเคอร์เซอร์ กด Tab เพื่อใช้ ไม่แตะข้อความเอง"
        }
    }
}

/// The keyboard event tap: feeds every keystroke to the core and carries out
/// what it decides.
final class Tap {
    static let shared = Tap()

    /// The self-test sets the mode itself.
    var testMode: Mode?
    /// The editor test decides each app's mode itself.
    var testModes: ((String) -> Mode)?
    var mode: Mode { testMode ?? testModes?(frontmost) ?? Prefs.shared.mode(for: frontmost) }
    /// Called with a short message to show after a fix.
    var onNote: ((String) -> Void)?
    /// Bundle IDs of apps RightType stays out of.
    var excluded: Set<String> = []
    /// Keys go to RightType's own palette, not the app behind it.
    var suspended = false

    private let engine = rt_engine_new()
    private var tap: CFMachPort?
    private var frontmost: String = ""

    var isRunning: Bool { tap != nil }

    /// Install the tap. Fails until the app has Accessibility permission.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in Tap.shared.handle(type, event) },
            userInfo: nil
        ) else { return false }
        tap = port
        let loop = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // RightType's own windows (the help alert) are not where you type.
            if app?.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.frontmost = app?.bundleIdentifier ?? ""
            }
            self?.reset(all: true)
        }
        InputSources.onChange = { [weak self] ours in
            // The user switched: the word in progress is no longer one word,
            // and a run shown as Thai goes back to the keys.
            guard !ours, let self else { return }
            var action = RtAction()
            if rt_layout_changed(self.engine, &action) { self.apply(&action) }
        }
        return true
    }

    var frontmostApp: String { frontmost }

    func reset(all: Bool) {
        rt_reset(engine, all)
        Hint.shared.hide()
    }

    func applyOptions(spelling: Bool, addresses: Bool) {
        rt_set_options(engine, spelling, addresses)
    }

    func setSnippets(_ list: [Snippet]) {
        rt_snippets_clear(engine)
        for s in list { rt_snippet_add(engine, s.trigger, s.text, s.scope) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            reset(all: true)
            return pass
        case .keyDown:
            break
        default:
            // A click may move the caret.
            reset(all: true)
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Inject.marker || suspended { return pass }
        if NSApp.isActive && testMode == nil {
            // Typing in RightType's own windows (settings): left alone.
            reset(all: true)
            return pass
        }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let shift = flags.contains(.maskShift)
        let command = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        Hint.shared.hide()

        if code == Keys.space && flags.contains(.maskControl) && flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand) && !shift {
            // Ctrl+Option+Space: the command palette, whatever the mode.
            if !repeating && !IsSecureEventInputEnabled() {
                reset(all: true)
                DispatchQueue.main.async { Palette.shared.show() }
            }
            return nil
        }
        let mode = self.mode
        guard mode != .off, !excluded.contains(frontmost), let layout = InputSources.current else {
            reset(all: true)
            return pass
        }

        if code == Keys.delete {
            if flags.contains(.maskControl) && shift && !flags.contains(.maskCommand) && !flags.contains(.maskAlternate) {
                // Ctrl+Shift+Backspace: fix the selected text.
                if !repeating { DispatchQueue.main.async { Selection.fix() } }
                return nil
            }
            if shift && !command {
                // Shift+Backspace: always swallowed, so a held key cannot turn
                // into Backspaces that delete what was just fixed.
                if !repeating && !IsSecureEventInputEnabled() { flip() }
                return nil
            }
            if command {
                reset(all: true)
                return pass
            }
            var action = RtAction()
            guard rt_backspace(engine, Int32(mode.rawValue), &action) else { return pass }
            // A run shown as Thai is re-rendered for the shorter keys.
            apply(&action)
            return nil
        }
        if command || flags.contains(.maskAlphaShift) {
            // A shortcut, or Option typing symbols; or CapsLock on, which this
            // port does not follow.
            reset(all: true)
            return pass
        }

        let boundary: UInt32
        switch code {
        case Keys.space: boundary = 0x20
        case Keys.returnKey, Keys.enter: boundary = 0x0D
        case Keys.tab: boundary = 0x09
        default:
            guard let key = Keys.qwerty(code, shift: shift) else {
                // Arrows, Escape, Forward Delete, function keys: the caret may move.
                reset(all: true)
                return pass
            }
            var action = RtAction()
            guard rt_key(engine, key, layout, Int32(mode.rawValue), &action) else { return pass }
            // Auto shows the run as Thai: the edit types the key's share of it;
            // Suggest shows it by the caret and lets the key through.
            let swallow = action.swallow
            apply(&action)
            return swallow ? nil : pass
        }
        if shift && boundary != 0x20 {
            reset(all: true)
            return pass
        }
        var action = RtAction()
        if boundary == 0x09, rt_tab(engine, &action) {
            // Tab takes Suggest's hint.
            apply(&action)
            return nil
        }
        guard rt_boundary(engine, boundary, layout, Int32(mode.rawValue), &action) else { return pass }
        // The word is fixed and the boundary key re-sent after it; or a Thai
        // run stands and only the layout follows (the key goes through).
        let swallow = action.swallow
        apply(&action, auto: true)
        return swallow ? nil : pass
    }

    private func flip() {
        var action = RtAction()
        rt_flip(engine, &action)
        apply(&action, auto: false)
    }

    private func apply(_ action: inout RtAction, auto: Bool = false) {
        defer { rt_action_clear(&action) }
        if let hint = action.hint {
            let text = String(cString: hint)
            if Prefs.shared.hints || testMode != nil {
                // After the key reaches the app, so the caret is where it ends up.
                DispatchQueue.main.async { Hint.shared.show("\(text)  ·  Tab") }
            }
        }
        Inject.backspaces(Int(action.backspaces))
        if let text = action.insert { Inject.type(String(cString: text)) }
        if action.boundary != 0 { Inject.boundary(action.boundary) }
        if let steps = action.steps { Macro.run(String(cString: steps)) }
        InputSources.select(action.layout)
        guard Prefs.shared.hints else { return }
        switch action.note {
        case RT_NOTE_FIXED: onNote?(auto ? "แก้ให้แล้ว · ⇧⌫ ย้อนกลับ" : "แก้แล้ว")
        case RT_NOTE_FIXED_MANY: onNote?("แก้ \(action.words) คำ")
        case RT_NOTE_REVERTED: onNote?("ย้อนกลับแล้ว")
        case RT_NOTE_NOTHING: onNote?("ไม่มีคำให้แก้")
        case RT_NOTE_TYPO: onNote?("แก้คำสะกดผิดแล้ว · ⇧⌫ ย้อนกลับ")
        default: break
        }
    }
}
