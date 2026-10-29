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
            // The app that was in front before (a terminal, say) may be one
            // RightType stays out of; the test types into its own window.
            onMain { Tap.shared.excluded = [] }
            func check(_ name: String, _ mode: Mode, _ layout: Int32, _ steps: () -> Void, _ expect: String) {
                onMain {
                    text.string = ""
                    Tap.shared.testMode = mode
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
            check("suggest leaves the word, Tab takes the fix", .suggest, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu "); Thread.sleep(forTimeInterval: 0.2); keys("\t")
            }, "สวัสดี ")
            check("suggest: Tab mid-word flips the word", .suggest, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu8iy["); Thread.sleep(forTimeInterval: 0.2); keys("\t")
            }, "สวัสดีครับ")
            check("suggest leaves text alone without Tab", .suggest, RT_LAYOUT_ENGLISH, {
                keys("l;ylfu ")
            }, "l;ylfu ")
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
            onMain { Tap.shared.setSnippets(Prefs.shared.snippets) }

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
