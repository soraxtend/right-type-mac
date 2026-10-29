import AppKit

/// `open -a RightType --args --selftest-editors`: per-app modes in a real
/// code editor (VS Code), typed through the real event tap.
///
/// The editor is opened as a separate instance with a throwaway profile in a
/// temporary folder (`--user-data-dir`), so the typist's own settings and open
/// files are never touched, and closed again afterwards. Before each case the
/// test checks that this instance is the app in front, and stops otherwise:
/// the keys would land somewhere else.
enum EditorTest {
    private static let source = CGEventSource(stateID: .hidSystemState)
    private static let vscode = "com.microsoft.VSCode"

    private struct Case {
        let name: String
        /// VS Code's own mode (nil: none set, so the code-editor default).
        let mode: Mode?
        /// -1 in `appModes`: set to follow the global mode.
        var followsGlobal = false
        let layout: Int32
        /// `^` is Shift+Backspace.
        let keys: String
        let expect: String
    }

    /// The global mode is Auto throughout.
    private static let cases: [Case] = [
        Case(name: "a code editor starts in Manual: typing stays", mode: nil, layout: RT_LAYOUT_ENGLISH,
             keys: "l;ylfu ", expect: "l;ylfu "),
        Case(name: "Manual: ⇧⌫ fixes the last word", mode: nil, layout: RT_LAYOUT_ENGLISH,
             keys: "l;ylfu ^", expect: "สวัสดี "),
        Case(name: "Manual: names and keywords stay", mode: nil, layout: RT_LAYOUT_ENGLISH,
             keys: "let getUserName = MAX_SIZE ", expect: "let getUserName = MAX_SIZE "),
        Case(name: "set to Auto: Thai fixed while typing", mode: .auto, layout: RT_LAYOUT_ENGLISH,
             keys: "l;ylfu8iy[", expect: "สวัสดีครับ"),
        Case(name: "set to Auto: English stays", mode: .auto, layout: RT_LAYOUT_ENGLISH,
             keys: "the quick brown fox ", expect: "the quick brown fox "),
        Case(name: "set to Auto: English typed on Thai fixed", mode: .auto, layout: RT_LAYOUT_THAI,
             keys: "hello world ", expect: "hello world "),
        Case(name: "set to Semi-auto: fixed when the word ends", mode: .semiAuto, layout: RT_LAYOUT_ENGLISH,
             keys: "l;ylfu ", expect: "สวัสดี "),
        Case(name: "set to Suggest: Tab takes the fix", mode: .suggest, layout: RT_LAYOUT_ENGLISH,
             keys: "l;ylfu \t", expect: "สวัสดี "),
        Case(name: "following the global mode (Auto)", mode: nil, followsGlobal: true, layout: RT_LAYOUT_ENGLISH,
             keys: "l;ylfu ", expect: "สวัสดี "),
        Case(name: "switched off: ⇧⌫ is the editor's own", mode: .off, layout: RT_LAYOUT_ENGLISH,
             keys: "l;ylfu ^", expect: "l;ylfu"),
    ]

    static func run() {
        DispatchQueue.global().async {
            let pb = NSPasteboard.general
            let saved = onMain { pb.string(forType: .string) }
            var result = (ran: 0, failed: 0)
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vscode) {
                result = session(url)
            } else {
                print("SKIP VS Code: not installed")
            }
            onMain {
                if let saved { pb.clearContents(); pb.setString(saved, forType: .string) }
                Tap.shared.testModes = nil
                print(result.ran == 0 ? "NOTHING RAN"
                      : result.failed == 0 ? "ALL PASSED (\(result.ran))" : "\(result.failed) FAILED")
                NSApp.terminate(nil)
            }
        }
    }

    private static func session(_ url: URL) -> (ran: Int, failed: Int) {
        // Short: the editor keeps a socket in its profile, and a socket's
        // path must fit in 103 characters.
        let dir = URL(fileURLWithPath: "/tmp/rt-\(UUID().uuidString.prefix(8))")
        let user = dir.appendingPathComponent("user")
        let file = dir.appendingPathComponent("test.js")
        defer { close(dir) }
        do {
            try FileManager.default.createDirectory(at: user.appendingPathComponent("User"), withIntermediateDirectories: true)
            try settings.write(to: user.appendingPathComponent("User/settings.json"), atomically: true, encoding: .utf8)
            try "".write(to: file, atomically: true, encoding: .utf8)
        } catch {
            print("FAIL VS Code: cannot make a test profile: \(error)")
            return (0, 1)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        config.arguments = ["--user-data-dir", user.path, "--extensions-dir", dir.appendingPathComponent("ext").path,
                            "--disable-extensions", "--new-window", file.path]
        let launched = DispatchSemaphore(value: 0)
        var app: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: config) { a, _ in app = a; launched.signal() }
        _ = launched.wait(timeout: .now() + 30)
        // A fresh profile takes a while to show its first window.
        Thread.sleep(forTimeInterval: 8)
        guard let app, !app.isTerminated else {
            print("FAIL VS Code: did not open, or quit at once")
            return (0, 1)
        }

        // Ready when what is typed comes back.
        var ready = false
        for _ in 0..<15 where !ready {
            guard bringForward(app) else { continue }
            clear()
            Inject.type("ready")
            Thread.sleep(forTimeInterval: 0.5)
            ready = read() == "ready"
        }
        guard ready else {
            print("FAIL VS Code: the editor never took typing")
            return (0, 1)
        }

        var appModes: [String: Int] = [:]
        onMain {
            Tap.shared.testMode = nil
            Tap.shared.testModes = { app in
                Prefs.resolve(app, enabled: true, paused: false, global: .auto, excluded: [], appModes: appModes)
            }
        }
        var failed = 0, ran = 0
        for c in cases {
            guard bringForward(app) else {
                let front = onMain { NSWorkspace.shared.frontmostApplication?.localizedName }
                print("FAIL VS Code: its window is not in front (\(front ?? "nothing") is); stopped before typing")
                return (ran, failed + 1)
            }
            onMain {
                appModes = c.followsGlobal ? [vscode: -1] : c.mode.map { [vscode: $0.rawValue] } ?? [:]
                Tap.shared.reset(all: true)
                InputSources.select(c.layout)
            }
            let resolved = onMain { Tap.shared.mode }
            clear()
            Thread.sleep(forTimeInterval: 0.3)
            onMain { Tap.shared.reset(all: true) }
            keys(c.keys)
            Thread.sleep(forTimeInterval: 0.8)
            let got = read()
            ran += 1
            let ok = got == c.expect
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") VS Code (\(resolved.name)): \(c.name): got \"\(got ?? "(nothing)")\" expected \"\(c.expect)\"")
        }
        return (ran, failed)
    }

    /// Put `app` in front. macOS lets only the app in front hand activation
    /// on, so RightType comes forward first and yields to it.
    private static func bringForward(_ app: NSRunningApplication) -> Bool {
        for _ in 0..<5 {
            onMain {
                NSApp.activate(ignoringOtherApps: true)
                if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
                _ = app.activate(options: [])
            }
            Thread.sleep(forTimeInterval: 0.6)
            if onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == app.processIdentifier { return true }
        }
        return false
    }

    /// Close every process of the test instance (its helpers too: they are
    /// the ones that name its profile), then remove the profile.
    private static func close(_ dir: URL) {
        // Asked to quit first; the editor does not always listen.
        for signal in ["-TERM", "-KILL"] {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = [signal, "-f", "--", dir.path]
            try? kill.run()
            kill.waitUntilExit()
            Thread.sleep(forTimeInterval: 2)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private static func clear() {
        Inject.key(0, flags: .maskCommand) // ⌘A
        Inject.key(Keys.delete)
    }

    /// The whole file, by copying it.
    private static func read() -> String? {
        let pb = NSPasteboard.general
        let before = onMain { pb.changeCount }
        Inject.key(0, flags: .maskCommand) // ⌘A
        Inject.key(Keys.c, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.5)
        return onMain { pb.changeCount != before ? pb.string(forType: .string) : nil }
    }

    /// A profile that types plainly: nothing completes, closes or indents.
    private static let settings = """
        {
          "editor.autoClosingBrackets": "never",
          "editor.autoClosingQuotes": "never",
          "editor.autoClosingComments": "never",
          "editor.autoSurround": "never",
          "editor.autoIndent": "none",
          "editor.formatOnType": false,
          "editor.quickSuggestions": { "other": false, "comments": false, "strings": false },
          "editor.suggestOnTriggerCharacters": false,
          "editor.acceptSuggestionOnEnter": "off",
          "editor.tabCompletion": "off",
          "editor.wordBasedSuggestions": "off",
          "editor.inlineSuggest.enabled": false,
          "editor.parameterHints.enabled": false,
          "editor.snippetSuggestions": "none",
          "editor.insertSpaces": false,
          "workbench.startupEditor": "none",
          "workbench.tips.enabled": false,
          "workbench.welcomePage.walkthroughs.openOnInstall": false,
          "window.restoreWindows": "none",
          "window.confirmBeforeClose": "never",
          "files.hotExit": "off",
          "security.workspace.trust.enabled": false,
          "telemetry.telemetryLevel": "off",
          "update.mode": "none",
          "extensions.autoCheckUpdates": false,
          "extensions.autoUpdate": false
        }
        """

    /// Type `s` key by key, named as on US QWERTY; `^` is Shift+Backspace.
    private static func keys(_ s: String) {
        for ch in s {
            if ch == "^" {
                press(Keys.delete, .maskShift)
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            let shifted = ch.isUppercase || "~!@#$%^&*()_+{}|:\"<>?".contains(ch)
            guard let code = Keys.all.first(where: { $0.qwerty == ch.unicodeScalars.first!.value })?.code
                ?? [" ": Keys.space, "\n": Keys.returnKey, "\t": Keys.tab][ch] else { continue }
            press(code, shifted ? .maskShift : [])
            if ch == "\t" || ch == " " { Thread.sleep(forTimeInterval: 0.15) }
        }
    }

    private static func press(_ code: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
            e.flags = flags
            e.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        DispatchQueue.main.sync(execute: work)
    }
}
