import AppKit
import ApplicationServices
import ServiceManagement

/// After an app's mode is set (`ToastAppMode`): "Auto mode in Notes".
func appModeNote(_ mode: Mode?, _ app: String) -> String {
    let label = mode?.title ?? AppDelegate.appModeLabel(nil)
    return tr("\(label) ใน \(app)", "\(label) in \(app)")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let toast = Toast()
    private var retry: Timer?
    private let prefs = Prefs.shared

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = Self.editMenu()
        let tap = Tap.shared
        tap.onNote = { [weak self] in self?.toast.show($0) }
        prefs.start()
        InputSources.start()
        NotificationCenter.default.addObserver(forName: .rightTypeStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateIcon()
            // The language may have changed.
            NSApp.mainMenu = Self.editMenu()
        }

        menu.delegate = self
        item.menu = menu
        updateIcon()

        if CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--selftest-editors") {
            if tap.start() {
                if CommandLine.arguments.contains("--selftest-editors") { EditorTest.run() } else { SelfTest.run() }
            } else {
                print("SELFTEST: no event tap (accessibility \(AXIsProcessTrusted()), "
                      + "listen \(CGPreflightListenEventAccess()), post \(CGPreflightPostEventAccess()))")
                NSApp.terminate(nil)
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), i + 1 < CommandLine.arguments.count {
            // `--render-settings <folder> en` draws the English interface.
            if i + 2 < CommandLine.arguments.count { uiThaiOverride = CommandLine.arguments[i + 2] != "en" }
            SettingsWindow.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--settings") {
            // Open the settings window at launch (also a way to look at it
            // without the keyboard permission).
            SettingsWindow.shared.show()
            if CommandLine.arguments.contains("--palette") { Palette.shared.show() }
            if !tap.start() { return }
        }
        if !tap.start() {
            // Ask once; then keep trying until the permission is granted.
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                if Tap.shared.start() {
                    timer.invalidate()
                    self?.updateIcon()
                    self?.toast.show(tr("RightType พร้อมใช้งาน", "RightType is ready"))
                }
            }
        }
    }

    /// A menu-bar app has no menus of its own, and without an Edit menu
    /// ⌘C, ⌘V, ⌘A and ⌘Z do nothing in its windows (the settings' text boxes).
    private static func editMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: tr("ปิดหน้าต่าง", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(app)
        let edit = NSMenuItem()
        let menu = NSMenu(title: tr("แก้ไข", "Edit"))
        menu.addItem(withTitle: tr("เลิกทำ", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: tr("ทำซ้ำ", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("ตัด", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: tr("คัดลอก", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: tr("วาง", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: tr("เลือกทั้งหมด", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = menu
        main.addItem(edit)
        return main
    }

    private func updateIcon() {
        guard let button = item.button else { return }
        button.image = Self.menuIcon
        let on = Tap.shared.isRunning && Tap.shared.mode != .off
        button.alphaValue = on ? 1 : 0.4
        button.toolTip = "RightType · " + (prefs.paused ? tr("หยุดชั่วคราว", "Paused") : Tap.shared.mode.title)
    }

    /// "Aก" as a template image, so macOS tints it for the menu bar (the app
    /// icon's letters in one colour, on one baseline).
    private static let menuIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let base = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let latin = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 13) ?? base
            let thai = NSFont(name: "SukhumvitSet-SemiBold", size: 14) ?? base
            let a = CTLineCreateWithAttributedString(NSAttributedString(string: "A", attributes: [.font: latin]))
            let k = CTLineCreateWithAttributedString(NSAttributedString(string: "ก", attributes: [.font: thai]))
            let aWidth = CTLineGetTypographicBounds(a, nil, nil, nil)
            let kWidth = CTLineGetTypographicBounds(k, nil, nil, nil)
            let x = (22 - (aWidth + 0.8 + kWidth)) / 2
            // Letters centred on their cap height.
            let baseline = (18 - latin.capHeight) / 2
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(a, ctx)
            ctx.textPosition = CGPoint(x: x + aWidth + 0.8, y: baseline)
            CTLineDraw(k, ctx)
            return true
        }
        image.isTemplate = true
        return image
    }()

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let tap = Tap.shared

        let header = NSMenuItem(title: tr("RightType สำหรับ macOS", "RightType for macOS"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !tap.isRunning {
            menu.addItem(action(tr("⚠︎ ต้องให้สิทธิ์ Accessibility ก่อน…", "⚠︎ Needs Accessibility permission…"), #selector(openAccessibility)))
        } else if !InputSources.thaiEnabled {
            menu.addItem(action(tr("⚠︎ ยังไม่ได้เพิ่มคีย์บอร์ด Thai…", "⚠︎ No Thai keyboard added yet…"), #selector(openKeyboards)))
        }
        menu.addItem(.separator())

        // The Windows tray menu (`tray.rs`), item for item and word for word.
        let enabled = action(tr("เปิดใช้งาน", "Enabled"), #selector(toggleEnabled))
        enabled.state = prefs.enabled ? .on : .off
        menu.addItem(enabled)
        let pause = NSMenuItem(title: tr("หยุดชั่วคราว", "Pause"), action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        for minutes in [10, 30, 60] {
            let m = action(minutes == 60 ? tr("1 ชั่วโมง", "For 1 hour") : tr("\(minutes) นาที", "For \(minutes) minutes"), #selector(pause(_:)))
            m.tag = minutes
            pauseMenu.addItem(m)
        }
        pauseMenu.addItem(.separator())
        let resume = action(tr("กลับมาทำงานเดี๋ยวนี้", "Resume now"), #selector(resume))
        resume.isEnabled = prefs.paused
        pauseMenu.addItem(resume)
        pause.submenu = pauseMenu
        menu.addItem(pause)
        menu.addItem(.separator())

        // Semi-auto is the Mac's own, between Auto and Manual.
        for mode in [Mode.auto, .semiAuto, .manual, .suggest] {
            let m = action(mode.title, #selector(setMode(_:)))
            m.tag = mode.rawValue
            m.state = prefs.mode == mode ? .on : .off
            menu.addItem(m)
        }

        let app = tap.frontmostApp
        let thisApp = NSMenuItem(title: tr("ในแอปนี้", "In this app"), action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.autoenablesItems = false
        if !app.isEmpty, app != Bundle.main.bundleIdentifier {
            let name = NSMenuItem(title: appName(app), action: nil, keyEquivalent: "")
            name.isEnabled = false
            appMenu.addItem(name)
            appMenu.addItem(.separator())
            let own = prefs.appMode(app)
            for mode in [nil as Mode?, .auto, .suggest, .manual, .semiAuto, .off] {
                let m = action(Self.appModeLabel(mode), #selector(setAppMode(_:)))
                m.representedObject = [app, mode?.rawValue ?? -1] as [Any]
                m.state = own == mode ? .on : .off
                appMenu.addItem(m)
            }
        } else {
            let none = NSMenuItem(title: tr("พิมพ์ในแอปที่ต้องการก่อน", "Type in an app first"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            appMenu.addItem(none)
        }
        thisApp.submenu = appMenu
        menu.addItem(thisApp)
        menu.addItem(.separator())

        let learn = action(tr("เรียนรู้คำใหม่", "Learn new words"), #selector(toggleLearn))
        learn.state = prefs.learnTyped ? .on : .off
        menu.addItem(learn)
        let startup = action(tr("เปิดพร้อม macOS", "Start with macOS"), #selector(toggleStartup))
        startup.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(startup)
        menu.addItem(action(tr("ซ่อมข้อความ…", "Fix text…"), #selector(openTools)))
        let settings = action(tr("ตั้งค่า…", "Settings…"), #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(action(tr("ปุ่มลัดและวิธีใช้…", "Hotkeys & help…"), #selector(showHelp)))
        menu.addItem(.separator())
        menu.addItem(action(tr("ออกจากโปรแกรม", "Quit"), #selector(quit)))
    }

    /// The labels of the "In this app" submenu (nil: the global mode).
    static func appModeLabel(_ mode: Mode?) -> String {
        switch mode {
        case nil: return tr("ใช้โหมดปกติ", "Use the default mode")
        case .off?: return tr("ปิดในแอปนี้", "Off in this app")
        case let m?: return m.title
        }
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        m.target = self
        return m
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        let mode = Mode(rawValue: sender.tag) ?? .manual
        prefs.mode = mode
        prefs.enabled = true
        toast.show(mode.title)
    }

    @objc private func toggleStartup() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            toast.show(tr("ตั้งค่าไม่สำเร็จ: ", "Could not change it: ") + error.localizedDescription)
        }
    }

    @objc private func toggleEnabled() {
        prefs.enabled.toggle()
        toast.show(prefs.enabled ? tr("RightType เปิดแล้ว", "RightType is on") : tr("RightType ปิดแล้ว", "RightType is off"))
    }

    @objc private func toggleLearn() {
        prefs.learnTyped.toggle()
        toast.show(prefs.learnTyped ? tr("เปิดการเรียนรู้คำใหม่", "Learning new words") : tr("ปิดการเรียนรู้คำใหม่", "Not learning new words"))
    }

    @objc private func pause(_ sender: NSMenuItem) {
        prefs.pause(minutes: sender.tag)
        toast.show(tr("หยุดชั่วคราว \(sender.tag) นาที", "Paused for \(sender.tag) minutes"))
    }

    @objc private func resume() {
        prefs.resume()
        toast.show(tr("RightType กลับมาทำงานแล้ว", "RightType is working again"))
    }

    @objc private func openPalette() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Palette.shared.show() }
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func openTools() {
        SettingsWindow.shared.show(page: .tools)
    }

    @objc private func fixSelection() {
        // Let the menu close and focus return to the app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Selection.fix() }
    }

    @objc private func setAppMode(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], let app = pair.first as? String,
              let raw = pair.last as? Int else { return }
        let mode = raw < 0 ? nil : Mode(rawValue: raw)
        prefs.setAppMode(app, mode)
        toast.show(appModeNote(mode, appName(app)))
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openKeyboards() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = tr("RightType · พิมพ์ผิดภาษา แก้ให้เอง", "RightType · typed in the wrong language, fixed")
        alert.informativeText = uiThai ? """
        ⇧⌫ (Shift + Delete) แก้คำล่าสุดที่พิมพ์ผิดภาษา กดซ้ำเพื่อแก้คำก่อนหน้าเพิ่ม (สูงสุด 8 คำ) \
        และกดอีกทีเมื่อแก้ครบแล้วเพื่อย้อนกลับ

        ⌃⇧⌫ แก้ข้อความที่เลือกไว้ทั้งก้อน

        ⌃⌥Space เปิด command palette: เปลี่ยนข้อความที่เลือก (ตัวพิมพ์ใหญ่ ปี พ.ศ. จำนวนเงิน ฯลฯ) \
        เปลี่ยนโหมด หยุดชั่วคราว ตั้งโหมดของแอปนี้

        ตั้งโหมดแยกแต่ละแอปได้ที่เมนู Aก → ในแอปนี้ \
        โปรแกรมเขียนโค้ดเริ่มที่โหมดกดแก้เอง ชื่อตัวแปรและคำสงวนจึงไม่ถูกแก้ระหว่างพิมพ์

        อัตโนมัติ แก้ตั้งแต่ระหว่างพิมพ์ ไม่ต้องรอวรรค (ภาษาไทยที่พิมพ์ติดกันก็แก้ได้) \
        ถ้าแก้ผิด กด ⇧⌫ เพื่อย้อน

        แนะนำ แสดงคำที่แก้แล้วข้างเคอร์เซอร์ กด Tab เพื่อใช้

        แก้เมื่อจบคำ แก้คำที่พิมพ์ผิดภาษาให้เองเมื่อเคาะวรรคหรือ Enter แล้วสลับคีย์บอร์ดให้

        คำย่อ: ตั้งใน ตั้งค่า → คำย่อ พิมพ์คำย่อแล้วเคาะวรรคเพื่อแปลงเป็นข้อความเต็ม

        ใช้ได้กับคีย์บอร์ด ABC / U.S. และ Thai (เกษมณี) \
        ไม่ทำงานในช่องรหัสผ่าน (macOS ไม่ส่งปุ่มให้) และในแอปที่ปิดไว้
        """ : """
        ⇧⌫ (Shift + Delete) fixes the last word typed on the wrong keyboard. Press it again to fix the word \
        before as well (up to 8 words), and once more after that to undo.

        ⌃⇧⌫ fixes the selected text.

        ⌃⌥Space opens the command palette: change the selected text (upper case, Buddhist year, \
        amounts in words…), change the mode, pause, set the mode for this app.

        Each app can have its own mode: Aก menu → In this app. \
        Code editors start in Manual mode, so names and keywords are not changed as you type.

        Auto fixes as you type, without waiting for a space (Thai typed without spaces too). \
        If it gets one wrong, press ⇧⌫ to undo.

        Suggest shows the fixed word by the text cursor; Tab takes it.

        Semi-auto fixes a word typed on the wrong keyboard when you press Space or Return, and switches the keyboard.

        Snippets: set them in Settings → Snippets. Type the trigger and a space to get the full text.

        Works with the ABC / U.S. and Thai (Kedmanee) keyboards. \
        Not in password fields (macOS does not pass their keys on) or in apps it is off in.
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
