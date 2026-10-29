import AppKit
import SwiftUI

/// The command palette (⌃⌥Space), as on Windows (`palette.rs`): a short list
/// of commands by the text cursor. Arrow keys and Return pick one, 1–9 picks
/// by number, typing searches, Esc closes. The app you were typing in stays
/// in front the whole time, so commands on the selection act on it.
final class Palette {
    static let shared = Palette()
    private var panel: PalettePanel?
    private let model = PaletteModel()
    private var monitor: Any?

    var isOpen: Bool { panel?.isVisible == true }

    func show() {
        if panel?.isVisible == true { close(); return }
        model.load()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = NSSize(width: 400, height: min(560, model.height))
        let anchor = Hint.caretRect().map { NSPoint(x: $0.minX, y: $0.minY - 6) }
        let screen = NSScreen.screens.first { NSMouseInRect(anchor ?? NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = anchor.map { NSPoint(x: $0.x, y: $0.y - size.height) }
            ?? NSPoint(x: visible.midX - size.width / 2, y: visible.midY)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        if origin.y < visible.minY + 8 { origin.y = (anchor?.y ?? visible.midY) + 30 }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        Tap.shared.suspended = true
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.key(e) == true ? nil : e
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
        Tap.shared.suspended = false
        Tap.shared.reset(all: true)
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onResign = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: PaletteView(model: model) { [weak self] item in self?.run(item) })
        let bg = NSVisualEffectView()
        bg.material = .menu
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            host.topAnchor.constraint(equalTo: bg.topAnchor),
            host.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        panel.contentView = bg
        return panel
    }

    /// Keys while the palette is open. True: handled here.
    private func key(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 53: close(); return true // Esc
        case 125: model.move(1); return true
        case 126: model.move(-1); return true
        case 36, 76:
            if let item = model.selectedItem { run(item) }
            return true
        default:
            if model.query.isEmpty, let c = e.characters, let n = Int(c), (1...9).contains(n),
               let item = model.numbered(n) {
                run(item)
                return true
            }
            return false
        }
    }

    private func run(_ item: PaletteItem) {
        close()
        // Let the app behind take the keyboard back before acting on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { item.action() }
    }
}

final class PalettePanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

struct PaletteItem: Identifiable {
    let id = UUID()
    let section: String
    let sectionIcon: String
    let title: String
    let icon: String
    var detail: String? = nil
    let action: () -> Void
}

final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { selected = 0 } }
    @Published var selected = 0
    private(set) var items: [PaletteItem] = []

    var filtered: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.lowercased().contains(q) || $0.section.lowercased().contains(q) }
    }

    var selectedItem: PaletteItem? {
        let list = filtered
        return list.indices.contains(selected) ? list[selected] : nil
    }

    func numbered(_ n: Int) -> PaletteItem? {
        let list = filtered
        return list.indices.contains(n - 1) ? list[n - 1] : nil
    }

    func move(_ by: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selected = (selected + by + count) % count
    }

    var height: CGFloat {
        let sections = Set(items.map(\.section)).count
        return CGFloat(items.count) * 32 + CGFloat(sections) * 26 + 70
    }

    func load() {
        query = ""
        selected = 0
        let prefs = Prefs.shared
        let tap = Tap.shared
        var list: [PaletteItem] = []

        // Words flipped back lately, while learning them is off.
        let reversed = takeString(rt_learn_reversed())?.split(separator: "\n").map(String.init) ?? []
        for word in reversed {
            list.append(PaletteItem(section: tr("คำที่เพิ่งพิมพ์", "Words just typed"), sectionIcon: "clock.arrow.circlepath",
                                    title: tr("ไม่ต้องแปลง “\(word)” อีก", "Leave “\(word)” as typed from now on"), icon: "arrow.uturn.backward") {
                rt_learn_keep(word)
                prefs.learnedVersion += 1
                tap.onNote?(tr("เพิ่ม “\(word)” แล้ว", "Added “\(word)”"))
            })
        }

        let fix = (tr("แก้ข้อความ", "Fix text"), "wrench.and.screwdriver")
        list.append(PaletteItem(section: fix.0, sectionIcon: fix.1, title: tr("แก้ข้อความที่เลือก", "Fix the selected text"),
                                icon: "character.textbox", detail: "⌃⇧⌫") { Selection.fix() })
        list.append(PaletteItem(section: fix.0, sectionIcon: fix.1, title: tr("พิมพ์ข้อความที่คัดลอกทีละปุ่ม", "Type the copied text key by key"),
                                icon: "keyboard") {
            if let text = NSPasteboard.general.string(forType: .string) { Macro.run("T" + text.replacingOccurrences(of: "\n", with: "\nK13\nT")) }
        })
        list.append(PaletteItem(section: fix.0, sectionIcon: fix.1, title: tr("หน้าต่างซ่อมข้อความ…", "Fix text window…"),
                                icon: "doc.text") { SettingsWindow.shared.show(page: .tools) })

        let sel = (tr("ข้อความที่เลือก", "Selected text"), "selection.pin.in.out")
        for (title, icon, kind) in transformList {
            list.append(PaletteItem(section: sel.0, sectionIcon: sel.1, title: title, icon: icon) {
                Selection.transform(kind, note: title)
            })
        }
        list.append(PaletteItem(section: sel.0, sectionIcon: sel.1, title: tr("เพิ่มคำที่เลือก", "Add the selected word"),
                                icon: "book.closed") {
            Selection.read { text in
                guard let text, let word = takeString(rt_learn_candidate(text)), prefs.learn(word) != nil else {
                    tap.onNote?(tr("เพิ่มคำนี้ไม่ได้", "Can't add this word"))
                    return
                }
                tap.onNote?(tr("เพิ่ม “\(word)” แล้ว", "Added “\(word)”"))
            }
        })

        let app = tap.frontmostApp
        let appName = NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.localizedName ?? app
        let here = (app.isEmpty ? tr("ที่นี่", "Here") : tr("ที่นี่ · \(appName)", "Here · \(appName)"), "macwindow")
        if prefs.paused {
            list.append(PaletteItem(section: here.0, sectionIcon: here.1, title: tr("กลับมาทำงานเดี๋ยวนี้", "Resume now"),
                                    icon: "play") { prefs.resume(); tap.onNote?(tr("RightType กลับมาทำงานแล้ว", "RightType is working again")) })
        } else {
            list.append(PaletteItem(section: here.0, sectionIcon: here.1, title: tr("หยุดชั่วคราว 30 นาที", "Pause for 30 minutes"),
                                    icon: "pause") { prefs.pause(minutes: 30); tap.onNote?(tr("หยุดชั่วคราว 30 นาที", "Paused for 30 minutes")) })
        }
        if !app.isEmpty {
            // This app's own mode (`PaletteOfferKeep`), or back to the global one.
            let own = prefs.appMode(app)
            if let own, own != .off {
                list.append(PaletteItem(section: here.0, sectionIcon: here.1, title: tr("โหมดในแอปนี้: \(own.name)", "Mode in this app: \(own.name)"),
                                        icon: "checkmark.circle", detail: tr("ตั้งค่า…", "Settings…")) {
                    SettingsWindow.shared.show(page: .apps)
                })
            }
            var choices: [(String, String, Mode?)] = [
                (Mode.manual, "keyboard"), (.suggest, "lightbulb"), (.auto, "bolt"),
            ].filter { $0.0 != own }.map { m, icon in
                (tr("ใช้\(m.title)ใน \(appName) ตลอด", "Always use \(m.title) in \(appName)"), icon, m as Mode?)
            }
            if own == .off {
                choices.append((tr("เปิดในแอปนี้อีกครั้ง", "On again in this app"), "power", nil))
            } else {
                if own != nil { choices.append((AppDelegate.appModeLabel(nil), "arrow.uturn.backward", nil)) }
                choices.append((AppDelegate.appModeLabel(.off), "power", .off))
            }
            for (title, icon, mode) in choices {
                list.append(PaletteItem(section: here.0, sectionIcon: here.1, title: title, icon: icon) {
                    prefs.setAppMode(app, mode)
                    tap.onNote?(appModeNote(mode, appName))
                })
            }
        }

        let modes = (tr("โหมด", "Mode"), "slider.horizontal.3")
        for (mode, icon) in [(Mode.auto, "bolt"), (.suggest, "lightbulb"), (.semiAuto, "space"), (.manual, "keyboard")] {
            let inUse = prefs.enabled && prefs.mode == mode
            list.append(PaletteItem(section: modes.0, sectionIcon: modes.1, title: mode.title, icon: icon,
                                    detail: inUse ? tr("ใช้อยู่", "in use") : nil) {
                prefs.mode = mode
                prefs.enabled = true
                tap.onNote?(mode.title)
            })
        }

        let opts = (tr("ตัวเลือก", "Options"), "gearshape")
        let toggles: [(String, String, ReferenceWritableKeyPath<Prefs, Bool>)] = [
            (tr("เปิดใช้งาน RightType", "RightType on"), "power.circle", \.enabled),
            (tr("เรียนรู้คำใหม่", "Learn new words"), "book", \.learnTyped),
            (tr("แก้คำไทยที่สะกดผิดบ่อย", "Fix common Thai misspellings"), "character.book.closed", \.spelling),
            (tr("แก้เว็บ อีเมล ตัวเลขที่พิมพ์บนแป้นไทย", "Fix web addresses, email and numbers on the Thai keyboard"), "at", \.addresses),
        ]
        for (title, icon, path) in toggles {
            let on = prefs[keyPath: path]
            list.append(PaletteItem(section: opts.0, sectionIcon: opts.1, title: title, icon: icon,
                                    detail: on ? tr("เปิด", "On") : tr("ปิด", "Off")) {
                prefs[keyPath: path].toggle()
                tap.onNote?("\(title): \(prefs[keyPath: path] ? tr("เปิด", "on") : tr("ปิด", "off"))")
            })
        }
        list.append(PaletteItem(section: opts.0, sectionIcon: opts.1, title: tr("ตัวเลือกและการตั้งค่า", "Options and settings"), icon: "gearshape") {
            SettingsWindow.shared.show()
        })
        items = list
    }
}

/// The changes made to selected text (the palette and the Tools page).
var transformList: [(String, String, Int32)] {
    [
        (tr("แก้เฉพาะคำที่พิมพ์ผิดแป้น", "Fix only the wrong-keyboard words"), "arrow.left.arrow.right", RT_TRANSFORM_REPAIR),
        (tr("สลับภาษาทั้งหมด", "Flip all of it to the other keyboard"), "globe", RT_TRANSFORM_FLIP),
        (tr("จัดอักษรไทยเป็นมาตรฐาน", "Thai in standard form"), "textformat", RT_TRANSFORM_NORMALIZE),
        (tr("จัดเว้นวรรคแบบไทย (ๆ ฯลฯ วงเล็บ)", "Thai spacing (ๆ ฯลฯ brackets)"), "text.alignleft", RT_TRANSFORM_SPACING),
        (tr("ปี พ.ศ. ↔ ค.ศ.", "Year พ.ศ. ↔ ค.ศ."), "calendar", RT_TRANSFORM_ERA),
        (tr("ตัวเลขเป็นคำอ่าน", "Number in Thai words"), "number", RT_TRANSFORM_NUMBER_WORDS),
        (tr("จำนวนเงินเป็นตัวอักษร (บาท)", "Amount in words (baht)"), "bahtsign", RT_TRANSFORM_BAHT_WORDS),
        (tr("เลขไทย ↔ เลขอารบิก", "Thai digits ↔ 0–9"), "number.square", RT_TRANSFORM_DIGITS),
        (tr("ตัวพิมพ์ใหญ่ทั้งหมด", "UPPER CASE"), "textformat.size.larger", RT_TRANSFORM_UPPER),
        (tr("ตัวพิมพ์เล็กทั้งหมด", "lower case"), "textformat.size.smaller", RT_TRANSFORM_LOWER),
        (tr("ขึ้นต้นคำด้วยตัวใหญ่", "Title Case"), "textformat.size", RT_TRANSFORM_TITLE),
        (tr("สลับตัวเล็ก/ใหญ่", "sWAP cASE"), "arrow.up.arrow.down", RT_TRANSFORM_SWAP_CASE),
    ]
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    let run: (PaletteItem) -> Void
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("↑↓ Enter · 1–9 · พิมพ์เพื่อค้นหา · Esc", "↑↓ Enter · 1–9 · type to search · Esc"))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 10)
            TextField(tr("ค้นหา", "Search"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searching)
                .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let list = model.filtered
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                            if i == 0 || list[i - 1].section != item.section {
                                Label(item.section, systemImage: item.sectionIcon)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
                            }
                            row(item, index: i)
                                .id(item.id)
                                .onTapGesture { run(item) }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: model.selected) { _ in
                    if let item = model.selectedItem { proxy.scrollTo(item.id) }
                }
            }
        }
        .onAppear { searching = true }
    }

    private func row(_ item: PaletteItem, index: Int) -> some View {
        let selected = index == model.selected
        return HStack(spacing: 10) {
            Text(index < 9 && model.query.isEmpty ? "\(index + 1)" : " ")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(index < 9 && model.query.isEmpty ? 0.5 : 0)))
            Image(systemName: item.icon).frame(width: 18)
            Text(item.title).lineLimit(1)
            Spacer()
            if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
        .overlay(alignment: .leading) {
            if selected { RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3, height: 16) }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}
