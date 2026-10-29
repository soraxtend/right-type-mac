import AppKit

/// `open -a RightType --args --selftest`: types into a window of its own
/// through the real event tap, as a person would, and prints what came out.
enum SelfTest {
    private static var window: NSWindow!
    private static var text: NSTextView!
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func run() {
        // The checks find palette commands by their Thai titles.
        uiThaiOverride = true
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "RightType self-test"
        text = NSTextView(frame: window.contentView!.bounds)
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        window.contentView!.addSubview(text)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)

        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 1)
            var failed = 0
            // The app that was in front before (a terminal, say) may be one
            // RightType stays out of; the test types into its own window.
            onMain { Tap.shared.excluded = [] }
            func check(_ name: String, _ mode: Mode?, _ layout: Int32, before: String = "", selected: Bool = false,
                       _ steps: () -> Void, _ expect: String) {
                onMain {
                    text.string = before
                    text.setSelectedRange(selected ? NSRange(location: 0, length: (before as NSString).length)
                                                   : NSRange(location: (before as NSString).length, length: 0))
                    Tap.shared.testMode = mode
                    Tap.shared.reset(all: true)
                    InputSources.select(layout)
                }
                Thread.sleep(forTimeInterval: 0.3)
                steps()
                Thread.sleep(forTimeInterval: 0.5)
                let got = onMain { text.string }
                report(name, got == expect, "got \"\(got)\" expected \"\(expect)\"")
            }
            func report(_ name: String, _ ok: Bool, _ detail: String = "") {
                if !ok { failed += 1 }
                print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": " + detail)")
            }

            check("manual flips word in progress", .manual, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu"); flip()
            }, "สวัสดี")
            check("manual flips it back", .manual, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu"); flip(); flip()
            }, "l;ylfu")
            check("manual flips two recent words", .manual, RT_LAYOUT_THAI, {
                keys("correct word "); flip(); flip()
            }, "correct word ")
            check("manual leaves typing alone", .manual, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu ")
            }, "l;ylfu ")
            check("semi-auto waits for the word to end", .semiAuto, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu")
            }, "l;ylfu")
            check("semi-auto fixes Thai typed on English", .semiAuto, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu ")
            }, "สวัสดี ")
            check("semi-auto switches layout and carries on", .semiAuto, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu "); keys("-v[")
            }, "สวัสดี ขอบ")
            check("semi-auto fixes English typed on Thai", .semiAuto, RT_LAYOUT_THAI, {
                keys("hello world ")
            }, "hello world ")
            check("semi-auto leaves English alone", .semiAuto, RT_LAYOUT_ENGLISH, {
                keys("the quick fox ")
            }, "the quick fox ")
            check("shift+backspace undoes a semi-auto fix", .semiAuto, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu "); flip()
            }, "l;ylfu ")
            check("auto fixes Thai while typing, no space", .auto, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu8iy[")
            }, "สวัสดีครับ")
            check("auto: backspace inside a fixed run", .auto, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu8iy[<<")
            }, "สวัสดีคร")
            check("auto: a Thai sentence with spaces", .auto, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu8iy[ mujouj ")
            }, "สวัสดีครับ ที่นี่ ")
            check("auto leaves English alone", .auto, RT_LAYOUT_ENGLISH, {
                keys("the quick brown fox ")
            }, "the quick brown fox ")
            check("auto fixes English typed on Thai at space", .auto, RT_LAYOUT_THAI, {
                keys("hello world ")
            }, "hello world ")
            check("suggest leaves the word, Tab takes the fix", .suggest, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu "); Thread.sleep(forTimeInterval: 0.2); keys("\t")
            }, "สวัสดี ")
            check("suggest: Tab mid-word flips the word", .suggest, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu8iy["); Thread.sleep(forTimeInterval: 0.2); keys("\t")
            }, "สวัสดีครับ")
            check("suggest leaves text alone without Tab", .suggest, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu ")
            }, "l;ylfu ")
            check("suggest: another key drops the hint, Tab is a Tab", .suggest, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu x"); Thread.sleep(forTimeInterval: 0.2); keys("\t")
            }, "l;ylfu x\t")
            check("suggest: English typed on Thai, Tab takes it", .suggest, RT_LAYOUT_THAI, {
                keys("hello "); Thread.sleep(forTimeInterval: 0.2); keys("\t")
            }, "hello ")
            do {
                onMain {
                    text.string = ""
                    Tap.shared.testMode = .suggest
                    Tap.shared.reset(all: true)
                    InputSources.select(RT_LAYOUT_ENGLISH)
                }
                Thread.sleep(forTimeInterval: 0.3)
                keys("l;ylfu ")
                Thread.sleep(forTimeInterval: 0.4)
                let shown = onMain { Hint.shared.isVisible }
                keys("\t")
                Thread.sleep(forTimeInterval: 0.4)
                let gone = onMain { !Hint.shared.isVisible }
                report("suggest shows its tag by the caret and Tab takes it away", shown && gone,
                       "shown \(shown), gone after Tab \(gone)")
            }

            onMain {
                Tap.shared.setSnippets([Snippet(trigger: ";addr", text: "123 Main St\nBangkok", scope: 2),
                                        Snippet(trigger: "teh", text: "the", scope: 3)])
            }
            check("a snippet becomes its text", .manual, RT_LAYOUT_ENGLISH, {
                keys("at ;addr ")
            }, "at 123 Main St\nBangkok ")
            check("a snippet works on the Thai keyboard too", .auto, RT_LAYOUT_THAI, {
                keys(";addr ")
            }, "123 Main St\nBangkok ")
            check("a typo of your own is put right", .semiAuto, RT_LAYOUT_ENGLISH, {
                keys("teh cat ")
            }, "the cat ")
            check("a typo of your own is left alone in manual", .manual, RT_LAYOUT_ENGLISH, {
                keys("teh ")
            }, "teh ")
            onMain {
                Tap.shared.setSnippets([Snippet(trigger: ";m", text: "x{กด Enter}y", scope: 2),
                                        Snippet(trigger: ";ok", text: "fine", scope: 1)])
            }
            check("a macro snippet presses its keys", .manual, RT_LAYOUT_ENGLISH, {
                keys(";m "); Thread.sleep(forTimeInterval: 0.4)
            }, "x\ny")
            check("an English-keyboard snippet stays put on Thai", .manual, RT_LAYOUT_THAI, {
                keys(";ok ")
            }, "วนา ")
            onMain { Tap.shared.setSnippets(Prefs.shared.snippets) }

            // The selection, with the hotkey and with the palette.
            check("ctrl+shift+backspace fixes the selection", .manual, RT_LAYOUT_ENGLISH,
                  before: "l;ylfu hello", selected: true, {
                press(Keys.delete, [.maskControl, .maskShift]); Thread.sleep(forTimeInterval: 0.8)
            }, "สวัสดี hello")
            func palette(_ query: String) {
                press(Keys.space, [.maskControl, .maskAlternate])
                Thread.sleep(forTimeInterval: 0.6)
                Inject.type(query)
                Thread.sleep(forTimeInterval: 0.3)
                press(Keys.returnKey, [])
                Thread.sleep(forTimeInterval: 0.9)
            }
            check("palette: upper case on the selection", .manual, RT_LAYOUT_ENGLISH,
                  before: "hello world", selected: true, { palette("ตัวพิมพ์ใหญ่") }, "HELLO WORLD")
            check("palette: พ.ศ. ↔ ค.ศ.", .manual, RT_LAYOUT_ENGLISH,
                  before: "พ.ศ. 2569", selected: true, { palette("ปี พ.ศ.") }, "ค.ศ. 2026")
            check("palette: baht in words", .manual, RT_LAYOUT_ENGLISH,
                  before: "1,250.50", selected: true, { palette("บาท") }, "หนึ่งพันสองร้อยห้าสิบบาทห้าสิบสตางค์")
            check("palette: only the wrong-keyboard words", .manual, RT_LAYOUT_ENGLISH,
                  before: "l;ylfu hello", selected: true, { palette("ผิดแป้น") }, "สวัสดี hello")
            do {
                onMain {
                    text.string = ""
                    Tap.shared.testMode = .semiAuto
                    Tap.shared.reset(all: true)
                    InputSources.select(RT_LAYOUT_ENGLISH)
                }
                Thread.sleep(forTimeInterval: 0.3)
                press(Keys.space, [.maskControl, .maskAlternate])
                Thread.sleep(forTimeInterval: 0.6)
                let opened = onMain { Palette.shared.isOpen }
                Inject.type("zz")
                press(53, []) // Esc
                Thread.sleep(forTimeInterval: 0.5)
                let closed = onMain { !Palette.shared.isOpen }
                // Typing goes back to the text, and RightType with it.
                keys("l;ylfu ")
                Thread.sleep(forTimeInterval: 0.5)
                let got = onMain { text.string }
                report("palette opens, Esc closes it, typing carries on", opened && closed && got == "สวัสดี ",
                       "opened \(opened), closed \(closed), then typed \"\(got)\"")
            }

            // RightType's own windows (settings) are left alone.
            check("RightType's own windows are not corrected", nil, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu8iy[ ")
            }, "l;ylfu8iy[ ")

            // Which mode an app gets.
            let vscode = "com.microsoft.VSCode", line = "jp.naver.line.mac"
            let rules: [(String, Mode, Mode)] = [
                ("a code editor starts in Manual", Prefs.resolve(vscode, enabled: true, paused: false, global: .auto, excluded: [], appModes: [:]), .manual),
                ("a code editor set to follow the global mode", Prefs.resolve(vscode, enabled: true, paused: false, global: .auto, excluded: [], appModes: [vscode: -1]), .auto),
                ("a code editor given Auto", Prefs.resolve(vscode, enabled: true, paused: false, global: .manual, excluded: [], appModes: [vscode: Mode.auto.rawValue]), .auto),
                ("another app follows the global mode", Prefs.resolve(line, enabled: true, paused: false, global: .suggest, excluded: [], appModes: [:]), .suggest),
                ("an app given its own mode", Prefs.resolve(line, enabled: true, paused: false, global: .auto, excluded: [], appModes: [line: Mode.suggest.rawValue]), .suggest),
                ("an app switched off", Prefs.resolve(line, enabled: true, paused: false, global: .auto, excluded: [line], appModes: [line: Mode.auto.rawValue]), .off),
                ("everything off while disabled", Prefs.resolve(vscode, enabled: false, paused: false, global: .auto, excluded: [], appModes: [:]), .off),
                ("everything off while paused", Prefs.resolve(line, enabled: true, paused: true, global: .auto, excluded: [], appModes: [line: Mode.auto.rawValue]), .off),
                ("an app left in Code mode by 0.2.0 gets Manual", Prefs.resolve(vscode, enabled: true, paused: false, global: .auto, excluded: [], appModes: [vscode: 5]), .manual),
                ("terminals are off by default", Prefs.resolve("com.apple.Terminal", enabled: true, paused: false, global: .auto, excluded: Array(defaultExcluded), appModes: [:]), .off),
            ]
            for (name, got, expect) in rules {
                report("per-app: \(name)", got == expect, "got \(got) expected \(expect)")
            }

            onMain {
                Tap.shared.testMode = nil
                print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
                NSApp.terminate(nil)
            }
        }
    }

    /// Type `s` key by key, named as on US QWERTY.
    private static func keys(_ s: String) {
        for ch in s {
            if ch == "<" { press(Keys.delete, []); continue }
            let shifted = ch.isUppercase || "~!@#$%^&*()_+{}|:\"<>?".contains(ch)
            guard let code = Keys.all.first(where: { $0.qwerty == ch.unicodeScalars.first!.value })?.code
                ?? [" ": Keys.space, "\n": Keys.returnKey, "\t": Keys.tab][ch] else { continue }
            press(code, shifted ? .maskShift : [])
        }
    }

    private static func flip() {
        press(Keys.delete, .maskShift)
        Thread.sleep(forTimeInterval: 0.15)
    }

    private static func press(_ code: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
            e.flags = flags
            e.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        DispatchQueue.main.sync(execute: work)
    }
}
