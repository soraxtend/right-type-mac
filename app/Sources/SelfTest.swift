import AppKit

/// `open -a RightType --args --selftest`: types into a window of its own
/// through the real event tap, as a person would, and prints what came out.
enum SelfTest {
    private static var window: NSWindow!
    private static var text: NSTextView!
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func run() {
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
            let saved = onMain { Tap.shared.mode }
            // The app that was in front before (a terminal, say) may be one
            // RightType stays out of; the test types into its own window.
            onMain { Tap.shared.excluded = [] }
            func check(_ name: String, _ mode: Mode, _ layout: Int32, _ steps: () -> Void, _ expect: String) {
                onMain {
                    text.string = ""
                    Tap.shared.mode = mode
                    Tap.shared.reset(all: true)
                    InputSources.select(layout)
                }
                Thread.sleep(forTimeInterval: 0.3)
                steps()
                Thread.sleep(forTimeInterval: 0.5)
                let got = onMain { text.string }
                let ok = got == expect
                if !ok { failed += 1 }
                print("\(ok ? "PASS" : "FAIL") \(name): got \"\(got)\" expected \"\(expect)\"")
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

            onMain {
                Tap.shared.mode = saved
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
                ?? [" ": Keys.space, "\n": Keys.returnKey][ch] else { continue }
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
