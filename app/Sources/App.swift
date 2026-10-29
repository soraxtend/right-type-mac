import AppKit
import ApplicationServices
import ServiceManagement

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
                    self?.toast.show("RightType พร้อมใช้งาน")
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
        app.submenu?.addItem(withTitle: "ปิดหน้าต่าง", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(app)
        let edit = NSMenuItem()
        let menu = NSMenu(title: "แก้ไข")
        menu.addItem(withTitle: "เลิกทำ", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "ทำซ้ำ", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "ตัด", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "คัดลอก", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "วาง", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "เลือกทั้งหมด", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = menu
        main.addItem(edit)
        return main
    }

    private func updateIcon() {
        guard let button = item.button else { return }
        button.image = Self.menuIcon
        let on = Tap.shared.isRunning && Tap.shared.mode != .off
        button.alphaValue = on ? 1 : 0.4
        button.toolTip = "RightType · " + (prefs.paused ? "หยุดชั่วคราว" : modeName(Tap.shared.mode))
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

    private func modeName(_ mode: Mode) -> String {
        mode == .off ? "ปิด" : "โหมด" + mode.name
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let tap = Tap.shared

        let header = NSMenuItem(title: "RightType สำหรับ macOS", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !tap.isRunning {
            menu.addItem(action("⚠︎ ต้องให้สิทธิ์ Accessibility ก่อน…", #selector(openAccessibility)))
        } else if !InputSources.thaiEnabled {
            menu.addItem(action("⚠︎ ยังไม่ได้เพิ่มคีย์บอร์ด Thai…", #selector(openKeyboards)))
        }
        menu.addItem(.separator())

        // The Windows tray menu (`tray.rs`), item for item and word for word.
        let enabled = action("เปิดใช้งาน", #selector(toggleEnabled))
        enabled.state = prefs.enabled ? .on : .off
        menu.addItem(enabled)
        let pause = NSMenuItem(title: "หยุดชั่วคราว", action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        for minutes in [10, 30, 60] {
            let m = action(minutes == 60 ? "1 ชั่วโมง" : "\(minutes) นาที", #selector(pause(_:)))
            m.tag = minutes
            pauseMenu.addItem(m)
        }
        pauseMenu.addItem(.separator())
        let resume = action("กลับมาทำงานเดี๋ยวนี้", #selector(resume))
        resume.isEnabled = prefs.paused
        pauseMenu.addItem(resume)
        pause.submenu = pauseMenu
        menu.addItem(pause)
        menu.addItem(.separator())

        // Semi-auto is the Mac's own, between Auto and Manual.
        for (mode, title) in [(Mode.auto, "โหมดอัตโนมัติ"), (.semiAuto, "โหมดแก้เมื่อจบคำ"),
                              (.manual, "โหมดกดแก้เอง"), (.suggest, "โหมดแนะนำ")] {
            let m = action(title, #selector(setMode(_:)))
            m.tag = mode.rawValue
            m.state = prefs.mode == mode ? .on : .off
            menu.addItem(m)
        }

        let app = tap.frontmostApp
        let thisApp = NSMenuItem(title: "ในแอปนี้", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.autoenablesItems = false
        if !app.isEmpty, app != Bundle.main.bundleIdentifier {
            let name = NSMenuItem(title: appName(app), action: nil, keyEquivalent: "")
            name.isEnabled = false
            appMenu.addItem(name)
            appMenu.addItem(.separator())
            let own = prefs.appMode(app)
            for (title, mode) in [("ใช้โหมดปกติ", nil as Mode?), ("โหมดอัตโนมัติ", .auto), ("โหมดแนะนำ", .suggest),
                                  ("โหมดกดแก้เอง", .manual), ("โหมดแก้เมื่อจบคำ", .semiAuto),
                                  ("ปิดในแอปนี้", .off)] {
                let m = action(title, #selector(setAppMode(_:)))
                m.representedObject = [app, mode?.rawValue ?? -1] as [Any]
                m.state = own == mode ? .on : .off
                appMenu.addItem(m)
            }
        } else {
            let none = NSMenuItem(title: "พิมพ์ในแอปที่ต้องการก่อน", action: nil, keyEquivalent: "")
            none.isEnabled = false
            appMenu.addItem(none)
        }
        thisApp.submenu = appMenu
        menu.addItem(thisApp)
        menu.addItem(.separator())

        let learn = action("เรียนรู้คำใหม่", #selector(toggleLearn))
        learn.state = prefs.learnTyped ? .on : .off
        menu.addItem(learn)
        let startup = action("เปิดพร้อม macOS", #selector(toggleStartup))
        startup.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(startup)
        menu.addItem(action("ซ่อมข้อความ…", #selector(openTools)))
        let settings = action("ตั้งค่า…", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(action("ปุ่มลัดและวิธีใช้…", #selector(showHelp)))
        menu.addItem(.separator())
        menu.addItem(action("ออกจากโปรแกรม", #selector(quit)))
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
        toast.show("โหมด" + mode.name)
    }

    @objc private func toggleStartup() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            toast.show("ตั้งค่าไม่สำเร็จ: \(error.localizedDescription)")
        }
    }

    @objc private func toggleEnabled() {
        prefs.enabled.toggle()
        toast.show(prefs.enabled ? "RightType เปิดแล้ว" : "RightType ปิดแล้ว")
    }

    @objc private func toggleLearn() {
        prefs.learnTyped.toggle()
        toast.show(prefs.learnTyped ? "เปิดการเรียนรู้คำใหม่" : "ปิดการเรียนรู้คำใหม่")
    }

    @objc private func pause(_ sender: NSMenuItem) {
        prefs.pause(minutes: sender.tag)
        toast.show("หยุดชั่วคราว \(sender.tag) นาที")
    }

    @objc private func resume() {
        prefs.resume()
        toast.show("RightType กลับมาทำงานแล้ว")
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
        let name = appName(app)
        // `ToastAppMode`: the label as the submenu shows it, then the app.
        let label = (sender.title == "ปิดในแอปนี้" ? "ปิด" : sender.title)
        toast.show("\(label) ใน \(name)")
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openKeyboards() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "RightType · พิมพ์ผิดภาษา แก้ให้เอง"
        alert.informativeText = """
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
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
