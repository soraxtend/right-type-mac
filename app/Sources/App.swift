import AppKit
import ApplicationServices
import ServiceManagement

/// Apps RightType stays out of unless the user says otherwise: terminals,
/// password managers and remote desktops, where retyping keys is unwelcome.
private let defaultExcluded: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    "com.apple.keychainaccess", "com.apple.Passwords",
    "com.microsoft.rdc.macos", "com.apple.ScreenSharing", "com.realvnc.vncviewer",
]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let toast = Toast()
    private var retry: Timer?
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ note: Notification) {
        defaults.register(defaults: ["mode": Mode.manual.rawValue, "excluded": Array(defaultExcluded)])
        let tap = Tap.shared
        tap.mode = Mode(rawValue: defaults.integer(forKey: "mode")) ?? .manual
        tap.excluded = Set(defaults.stringArray(forKey: "excluded") ?? [])
        tap.onNote = { [weak self] in self?.toast.show($0) }
        InputSources.start()

        menu.delegate = self
        item.menu = menu
        updateIcon()

        if CommandLine.arguments.contains("--selftest") {
            if tap.start() {
                SelfTest.run()
            } else {
                print("SELFTEST: no event tap (accessibility \(AXIsProcessTrusted()), "
                      + "listen \(CGPreflightListenEventAccess()), post \(CGPreflightPostEventAccess()))")
                NSApp.terminate(nil)
            }
            return
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

    private func updateIcon() {
        guard let button = item.button else { return }
        button.image = Self.menuIcon
        let on = Tap.shared.isRunning && Tap.shared.mode != .off
        button.alphaValue = on ? 1 : 0.4
        button.toolTip = "RightType · " + modeName(Tap.shared.mode)
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
        switch mode {
        case .off: return "ปิด"
        case .manual: return "Manual"
        case .semiAuto: return "Semi-auto"
        case .auto: return "Auto"
        }
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

        for (mode, title) in [(Mode.off, "ปิด"),
                              (.manual, "Manual · แก้เมื่อกด ⇧⌫"),
                              (.semiAuto, "Semi-auto · แก้ให้เมื่อจบคำ"),
                              (.auto, "Auto · แก้ระหว่างพิมพ์")] {
            let m = action(title, #selector(setMode(_:)))
            m.tag = mode.rawValue
            m.state = tap.mode == mode ? .on : .off
            menu.addItem(m)
        }
        menu.addItem(.separator())

        let fix = action("แก้ข้อความที่เลือก", #selector(fixSelection))
        fix.keyEquivalent = "\u{8}"
        fix.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(fix)

        let app = tap.frontmostApp
        if !app.isEmpty, app != Bundle.main.bundleIdentifier {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.localizedName ?? app
            let ex = action("ไม่ทำงานใน \(name)", #selector(toggleExcluded(_:)))
            ex.representedObject = app
            ex.state = tap.excluded.contains(app) ? .on : .off
            menu.addItem(ex)
        }
        let login = action("เปิดเมื่อเข้าสู่ระบบ", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action("วิธีใช้", #selector(showHelp)))
        menu.addItem(action("ออก", #selector(quit)))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        m.target = self
        return m
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        let mode = Mode(rawValue: sender.tag) ?? .manual
        Tap.shared.mode = mode
        Tap.shared.reset(all: true)
        defaults.set(mode.rawValue, forKey: "mode")
        updateIcon()
        toast.show("โหมด " + modeName(mode))
    }

    @objc private func fixSelection() {
        // Let the menu close and focus return to the app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Selection.fix() }
    }

    @objc private func toggleExcluded(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        let tap = Tap.shared
        if tap.excluded.contains(app) { tap.excluded.remove(app) } else { tap.excluded.insert(app) }
        defaults.set(Array(tap.excluded), forKey: "excluded")
    }

    @objc private func toggleLogin() {
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

        Semi-auto แก้คำที่พิมพ์ผิดภาษาให้เองเมื่อเคาะวรรคหรือ Enter แล้วสลับคีย์บอร์ดให้

        Auto แก้ตั้งแต่ระหว่างพิมพ์ ไม่ต้องรอวรรค (ภาษาไทยที่พิมพ์ติดกันก็แก้ได้) \
        ถ้าแก้ผิด กด ⇧⌫ เพื่อย้อน

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
