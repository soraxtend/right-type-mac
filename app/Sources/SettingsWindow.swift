import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The settings window, as on Windows (`settings.rs`): a sidebar of pages,
/// every change applied and saved the moment it is made.
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let nav = SettingsNav()

    private static var title: String { tr("RightType — ตั้งค่า", "RightType — Settings") }

    func show(page: SettingsPage? = nil) {
        if let page { nav.page = page }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            NotificationCenter.default.addObserver(forName: .rightTypeStateChanged, object: nil, queue: .main) { [weak w] _ in
                // The language may have changed.
                w?.title = Self.title
            }
            w.contentView = NSHostingView(rootView: SettingsView(nav: nav, prefs: Prefs.shared))
            w.contentMinSize = NSSize(width: 700, height: 520)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.title = Self.title
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension SettingsWindow {
    /// `--render-settings <folder>`: every page (and the palette) drawn to a
    /// PNG, to look at the windows without opening them.
    static func render(to folder: URL) {
        let nav = SettingsNav()
        for page in SettingsPage.allCases {
            nav.page = page
            let view = NSHostingView(rootView: SettingsView(nav: nav, prefs: Prefs.shared))
            write(view, NSSize(width: 780, height: 700), folder.appendingPathComponent("settings-\(page.rawValue).png"))
        }
        let model = PaletteModel()
        model.load()
        let palette = NSHostingView(rootView: PaletteView(model: model) { _ in }
            .background(Color(nsColor: .windowBackgroundColor)))
        write(palette, NSSize(width: 400, height: 900), folder.appendingPathComponent("palette.png"))
    }

    private static func write(_ view: NSView, _ size: NSSize, _ url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, keyboard, tools, hotkeys, learned, snippets, apps, privacy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return tr("ทั่วไป", "General")
        case .keyboard: return tr("แป้นพิมพ์", "Keyboard")
        case .tools: return tr("เครื่องมือ", "Tools")
        case .hotkeys: return tr("ปุ่มลัด", "Hotkeys")
        case .learned: return tr("คำที่จำไว้", "Learned words")
        case .snippets: return tr("คำย่อ", "Snippets")
        case .apps: return tr("แอปที่ไม่ใช้", "Ignored apps")
        case .privacy: return tr("ความเป็นส่วนตัว", "Privacy")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .keyboard: return "keyboard"
        case .tools: return "wrench.and.screwdriver"
        case .hotkeys: return "bolt"
        case .learned: return "book.closed"
        case .snippets: return "curlybraces"
        case .apps: return "macwindow"
        case .privacy: return "lock"
        }
    }
}

final class SettingsNav: ObservableObject {
    @Published var page: SettingsPage = .general
}

struct SettingsView: View {
    @ObservedObject var nav: SettingsNav
    @ObservedObject var prefs: Prefs

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(nav.page.title).font(.system(size: 26, weight: .semibold))
                    page
                }
                .padding(.horizontal, 26).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RightType").font(.system(size: 17, weight: .semibold))
            Text(tr("พิมพ์ผิดภาษา แก้ให้เอง", "Wrong keyboard, fixed")).font(.caption).foregroundStyle(.secondary).padding(.bottom, 14)
            ForEach(SettingsPage.allCases) { p in
                Button { nav.page = p } label: {
                    Label(p.title, systemImage: p.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(nav.page == p ? Color.primary.opacity(0.08) : .clear))
                        .overlay(alignment: .leading) {
                            if nav.page == p { RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3, height: 16).offset(x: -6) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fontWeight(nav.page == p ? .semibold : .regular)
            }
            Spacer()
            Text(tr("เวอร์ชัน \(version)", "Version \(version)")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 210)
    }

    @ViewBuilder private var page: some View {
        switch nav.page {
        case .general: GeneralPage(prefs: prefs, nav: nav)
        case .keyboard: KeyboardPage(prefs: prefs)
        case .tools: ToolsPage()
        case .hotkeys: HotkeysPage()
        case .learned: LearnedPage(prefs: prefs)
        case .snippets: SnippetsPage(prefs: prefs)
        case .apps: AppsPage(prefs: prefs)
        case .privacy: PrivacyPage()
        }
    }
}

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

// MARK: Building blocks, after `ui::card` and `ui::field` on Windows.

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

struct Heading: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold)).padding(.top, 4)
    }
}

struct ToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var on: Bool
    var last = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden()
            }
            .padding(.vertical, 10)
            if !last { Divider() }
        }
    }
}

// MARK: General

struct GeneralPage: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var nav: SettingsNav
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        Heading(title: tr("วิธีแก้คำ", "Correction mode"), icon: "slider.horizontal.3")
        Card {
            Picker("", selection: $prefs.mode) {
                Label(Mode.auto.name, systemImage: "bolt").tag(Mode.auto)
                Label(Mode.suggest.name, systemImage: "lightbulb").tag(Mode.suggest)
                Label(Mode.semiAuto.name, systemImage: "space").tag(Mode.semiAuto)
                Label(Mode.manual.name, systemImage: "keyboard").tag(Mode.manual)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.top, 10)
            Text(prefs.mode.detail).font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
        }
        Heading(title: tr("การทำงาน", "Behaviour"), icon: "gearshape")
        Card {
            ToggleRow(icon: "power", title: tr("เปิดใช้งาน RightType", "RightType on"),
                      detail: tr("เปิดหรือปิดได้ทุกเมื่อจากเมนูบาร์หรือ ⌃⌥Space", "Turn it on or off anytime from the menu bar or ⌃⌥Space"), on: $prefs.enabled)
            ToggleRow(icon: "play", title: tr("เปิดพร้อม macOS", "Start with macOS"),
                      detail: tr("ทำงานเงียบ ๆ ที่เมนูบาร์เมื่อเข้าสู่ระบบ", "Runs quietly in the menu bar when you log in"), on: Binding(get: { login }, set: setLogin))
            ToggleRow(icon: "book", title: tr("เรียนรู้คำใหม่", "Learn new words"),
                      detail: tr("จำคำภาษาอังกฤษที่คุณพิมพ์บ่อย (3 ครั้ง) เก็บในเครื่องนี้เท่านั้น", "Remembers English words you type often (3 times), on this Mac only"), on: $prefs.learnTyped)
            ToggleRow(icon: "arrow.uturn.backward", title: tr("จำคำที่แก้กลับ", "Remember words you undo"),
                      detail: tr("กด ⇧⌫ ย้อนคำที่ RightType แก้ให้ แปลว่าคำเดิมถูกแล้ว ครั้งหน้าจะไม่แก้อีก", "Undoing a fix with ⇧⌫ means the word was right, so it is left alone next time"), on: $prefs.learnReversed)
            ToggleRow(icon: "cursorarrow.rays", title: tr("แสดงป้ายข้างเคอร์เซอร์", "Hints at the text cursor"),
                      detail: tr("คำแนะนำของโหมดแนะนำ (กด Tab เพื่อใช้) และข้อความหลังแก้คำ", "Suggest mode's fixes (Tab takes them) and a note after each fix"), on: $prefs.hints)
            ToggleRow(icon: "character.book.closed", title: tr("แก้คำไทยที่สะกดผิดบ่อย", "Fix common Thai misspellings"),
                      detail: tr("แก้คำสะกดผิดที่พบบ่อยราว 60 คำ เมื่อจบคำ (อัตโนมัติ / แก้เมื่อจบคำ)", "About 60 common misspellings, fixed when the word ends (Auto / Semi-auto)"), on: $prefs.spelling, last: true)
            Divider()
            HStack {
                Text(tr("คำที่เรียนรู้แล้ว: ", "Learned words: ") + "\(prefs.learnedVersion >= 0 ? prefs.learnedCount : 0)").foregroundStyle(.secondary)
                Spacer()
                Button { nav.page = .learned } label: { Label(tr("แก้ไข…", "Edit…"), systemImage: "pencil") }
            }
            .padding(.vertical, 10)
        }
        Heading(title: tr("ภาษา", "Language"), icon: "globe")
        Card {
            HStack {
                Text(tr("ภาษาของหน้าจอ RightType", "RightType's own language"))
                Spacer()
                Picker("", selection: $prefs.language) {
                    Text(tr("ตามระบบ", "As macOS")).tag(0)
                    Text("ไทย").tag(1)
                    Text("English").tag(2)
                }
                .labelsHidden().fixedSize()
            }
            .padding(.vertical, 10)
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Tap.shared.onNote?(tr("ตั้งค่าไม่สำเร็จ: ", "Could not change it: ") + error.localizedDescription)
        }
        login = SMAppService.mainApp.status == .enabled
    }
}

// MARK: Keyboard

struct KeyboardPage: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        Heading(title: tr("แป้นพิมพ์ที่ใช้", "Your keyboards"), icon: "keyboard")
        Card {
            let sources = InputSources.enabledSummary
            row(tr("ไทย", "Thai"), sources.thai.isEmpty ? tr("ยังไม่ได้เพิ่ม — เพิ่ม Thai (เกษมณี) ใน System Settings", "Not added yet — add Thai (Kedmanee) in System Settings") : sources.thai.joined(separator: ", "),
                ok: !sources.thai.isEmpty)
            Divider()
            row(tr("อังกฤษ", "English"), sources.english.isEmpty ? tr("ยังไม่มี — เพิ่ม ABC หรือ U.S.", "None yet — add ABC or U.S.") : sources.english.joined(separator: ", "),
                ok: !sources.english.isEmpty)
            if !sources.other.isEmpty {
                Divider()
                row(tr("ไม่ยุ่ง", "Left alone"), sources.other.joined(separator: ", "), ok: true)
            }
            Divider()
            HStack {
                Text(tr("RightType ดูว่าคีย์บอร์ดเป็นไทยหรืออังกฤษจากตัวอักษรที่แต่ละปุ่มพิมพ์ ไม่ได้ดูจากชื่อ", "RightType tells Thai from English by the letters each key types, not by the keyboard's name"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("เปิดการตั้งค่าคีย์บอร์ด…", "Keyboard Settings…")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }
            .padding(.vertical, 10)
        }
        Heading(title: tr("ระหว่างพิมพ์", "While you type"), icon: "text.cursor")
        Card {
            ToggleRow(icon: "at", title: tr("ที่อยู่เว็บ อีเมล และตัวเลข", "Web addresses, email and numbers"),
                      detail: tr("พิมพ์ตอนแป้นไทยเปิดอยู่ แก้กลับให้ เช่น name@gmail.com, www.…, 100, 10:30", "Typed with the Thai keyboard on, they come back: name@gmail.com, www.…, 100, 10:30"), on: $prefs.addresses)
            ToggleRow(icon: "character.book.closed", title: tr("แก้คำไทยที่สะกดผิดบ่อย", "Fix common Thai misspellings"),
                      detail: tr("เช่น อนุญาติ → อนุญาต และอีกราว 60 คำ", "Such as อนุญาติ → อนุญาต, and about 60 more"), on: $prefs.spelling, last: true)
        }
    }

    private func row(_ title: String, _ value: String, ok: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(title).frame(width: 80, alignment: .leading)
            Text(value).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

// MARK: Tools

struct ToolsPage: View {
    @State private var text = ""
    @State private var note = ""

    var body: some View {
        Heading(title: tr("ซ่อมข้อความ", "Fix text"), icon: "doc.text")
        Card {
            Text(tr("วางข้อความที่พิมพ์ผิดแป้น แล้วกดแก้ คำที่พิมพ์ผิดภาษาจะถูกแก้ ที่เหลือคงเดิม", "Paste text typed on the wrong keyboard and press Fix. Words in the wrong language are fixed; the rest stays."))
                .font(.callout).foregroundStyle(.secondary).padding(.top, 10)
            TextEditor(text: $text)
                .font(.system(size: 14))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                .padding(.vertical, 8)
            HStack {
                Button(tr("แก้", "Fix")) { apply(RT_TRANSFORM_REPAIR) }.keyboardShortcut(.defaultAction)
                Button(tr("วางแล้วแก้", "Paste and fix")) {
                    text = NSPasteboard.general.string(forType: .string) ?? ""
                    apply(RT_TRANSFORM_REPAIR)
                }
                Menu(tr("เปลี่ยนแบบอื่น", "Other changes")) {
                    ForEach(transformList, id: \.2) { t in Button(t.0) { apply(t.2) } }
                }
                .fixedSize()
                Spacer()
                Text(note).font(.caption).foregroundStyle(.secondary)
                Button(tr("คัดลอก", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    note = tr("คัดลอกแล้ว", "Copied")
                }
            }
            .padding(.bottom, 10)
        }
        Heading(title: tr("ข้อความที่เลือกในแอปอื่น", "Selected text in other apps"), icon: "selection.pin.in.out")
        Card {
            Text(tr("เลือกข้อความในแอปไหนก็ได้ แล้วกด ⌃⇧⌫ เพื่อแก้คำที่พิมพ์ผิดแป้น หรือกด ⌃⌥Space แล้วเลือกจากหมวด “ข้อความที่เลือก” (ตัวพิมพ์ใหญ่ ปี พ.ศ. จำนวนเงินเป็นตัวอักษร ฯลฯ)", "Select text in any app and press ⌃⇧⌫ to fix the wrong-keyboard words, or press ⌃⌥Space and pick from “Selected text” (upper case, Buddhist year, amounts in words…)"))
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
        }
    }

    private func apply(_ kind: Int32) {
        guard !text.isEmpty, let out = takeString(rt_transform(kind, text)) else { return }
        note = out == text ? tr("ไม่มีอะไรต้องเปลี่ยน", "Nothing to change") : tr("แก้แล้ว", "Fixed")
        text = out
    }
}

// MARK: Hotkeys

struct HotkeysPage: View {
    private let keys: [(String, String)] = [
        ("⇧⌫", tr("แก้คำล่าสุดในที่เดิม กดซ้ำเพื่อแก้ย้อนไปได้ถึง 8 คำ กดอีกทีหลังแก้ครบเพื่อย้อนกลับทั้งหมด",
                  "Fixes the last word in place. Press again to fix up to 8 words back, and once more after that to undo them all.")),
        ("⌃⇧⌫", tr("แก้ข้อความที่เลือกอยู่ (ใช้คลิปบอร์ดชั่วคราว แล้วคืนของเดิมให้)",
                   "Fixes the selected text (through the clipboard, which is put back afterwards).")),
        ("Tab", tr("ใช้คำแนะนำของโหมดแนะนำ (ภายใน 4 วินาที)", "Takes Suggest mode's fix (within 4 seconds).")),
        ("⌃⌥Space", tr("Command palette: แก้ข้อความ, เปลี่ยนข้อความที่เลือก, โหมด, หยุดชั่วคราว, ปิดในแอปนี้ และอื่น ๆ",
                       "Command palette: fix text, change the selected text, modes, pause, off in this app, and more.")),
    ]

    var body: some View {
        Heading(title: tr("ปุ่มลัด", "Hotkeys"), icon: "bolt")
        Card {
            ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(k.0).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                        .frame(width: 100, alignment: .leading)
                    Text(k.1).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.vertical, 10)
                if i < keys.count - 1 { Divider() }
            }
        }
        Text(tr("บน Mac ใช้ ⇧⌫ (Shift+Delete) แทน Shift+Backspace ของ Windows ปุ่มที่ใช้ CapsLock บน Windows ย้ายมาอยู่ใน ⌃⌥Space", "On the Mac, ⇧⌫ (Shift+Delete) stands in for Windows' Shift+Backspace. What CapsLock does on Windows lives in ⌃⌥Space."))
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: Learned words

struct LearnedPage: View {
    @ObservedObject var prefs: Prefs
    @State private var word = ""
    @State private var picked: Set<String> = []
    @State private var note = ""

    var body: some View {
        let words = prefs.learnedVersion >= 0 ? prefs.learnedWords : []
        Text(tr("คำที่ RightType จะไม่แก้ ปล่อยไว้ตามที่พิมพ์ เพิ่มคำได้ด้วยตัวเอง หรือให้ RightType จำเองเมื่อคุณกด ⇧⌫ ย้อนคำที่มันแก้", "Words RightType leaves as typed. Add them yourself, or RightType remembers one when you undo its fix with ⇧⌫."))
            .foregroundStyle(.secondary)
        Card {
            HStack {
                TextField(tr("คำใหม่ เช่น kubernetes หรือ ต๊าช", "A new word, such as kubernetes or ต๊าช"), text: $word)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit(add)
                Button(tr("เพิ่ม", "Add"), action: add).buttonStyle(.borderedProminent)
                Spacer()
                Button(tr("ลบ", "Remove")) {
                    guard !picked.isEmpty else { note = tr("เลือกคำในรายการก่อน", "Pick words in the list first"); return }
                    prefs.replaceLearned(words.filter { !picked.contains($0) })
                    picked = []
                }
            }
            .padding(.vertical, 10)
            List(words, id: \.self, selection: $picked) { Text($0) }
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
            HStack {
                Button(tr("นำเข้า…", "Import…"), action: importFile)
                Button(tr("ส่งออก…", "Export…")) { exportFile(words) }
                Text(note).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("ล้างทั้งหมด", "Clear all"), role: .destructive) { confirmClear() }
            }
            .padding(.vertical, 10)
        }
        HStack {
            Text(tr("\(words.count) คำ · บันทึกไว้ในเครื่องนี้เท่านั้น", "\(words.count) words · kept on this Mac only")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(tr("เปิดตำแหน่งไฟล์", "Show the file")) {
                NSWorkspace.shared.activateFileViewerSelecting([prefs.learnedFile()])
            }
        }
    }

    private func add() {
        guard !word.isEmpty else { return }
        if let learned = prefs.learn(word) { note = tr("เพิ่ม “\(learned)” แล้ว", "Added “\(learned)”"); word = "" } else { note = tr("เพิ่มคำนี้ไม่ได้", "Can't add this word") }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let before = prefs.learnedWords
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let skipped = prefs.replaceLearned(before + lines)
        let added = prefs.learnedCount - before.count
        note = skipped > 0 ? tr("เพิ่ม \(added) คำจากไฟล์แล้ว ข้าม \(skipped) บรรทัดที่ไม่ใช่คำเดียว", "Added \(added) words from the file; skipped \(skipped) lines that were not one word")
            : tr("เพิ่ม \(added) คำจากไฟล์แล้ว", "Added \(added) words from the file")
    }

    private func exportFile(_ words: [String]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RightType learned words.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? (words.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        note = tr("บันทึก \(words.count) คำลงไฟล์แล้ว", "Saved \(words.count) words to the file")
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = tr("ล้างคำที่จำไว้ทั้งหมด?", "Clear all learned words?")
        alert.informativeText = tr("RightType จะลืมทุกคำที่เรียนรู้มา ย้อนไม่ได้", "RightType forgets every word it has learned. This cannot be undone.")
        alert.addButton(withTitle: tr("ล้างทั้งหมด", "Clear all"))
        alert.addButton(withTitle: tr("ยกเลิก", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { prefs.clearLearned() }
    }
}

// MARK: Snippets

struct SnippetsPage: View {
    @ObservedObject var prefs: Prefs
    @State private var picked: String?
    @State private var trigger = ""
    @State private var text = ""
    @State private var scope: Int32 = 2
    @State private var note = ""

    private let fields: [(String, String)] = [
        ("{วันที่}", "2 ตุลาคม 2569"), ("{วันที่เต็ม}", "วันพฤหัสบดีที่ 2 ตุลาคม พ.ศ. 2569"),
        ("{วันที่ย่อ}", "2 ต.ค. 69"), ("{วันที่เลขไทย}", "๒ ตุลาคม ๒๕๖๙"), ("{วันที่ตัวเลข}", "02/10/2569"),
        ("{เวลา}", "14.30 น."), ("{date}", "2 October 2026"), ("{date-us}", "October 2, 2026"),
        ("{iso}", "2026-10-02"), ("{time}", "14:30"),
    ]
    private let steps: [(String, String)] = [
        ("{กด Cmd+B}", tr("กดปุ่มลัด", "press a shortcut")), ("{รอ 300}", tr("รอ 300 มิลลิวินาที", "wait 300 ms")),
        ("{คลิปบอร์ด}", tr("พิมพ์ข้อความที่คัดลอก", "type the copied text")),
    ]

    var body: some View {
        Text(tr("พิมพ์คำย่อแล้วกด Space หรือ Enter เพื่อแปลงเป็นข้อความเต็ม", "Type a trigger and press Space or Return to get the full text.")).foregroundStyle(.secondary)
        Card {
            Table(prefs.snippets, selection: $picked) {
                TableColumn(tr("คำย่อ", "Trigger")) { Text($0.trigger).font(.system(.body, design: .monospaced)) }.width(110)
                TableColumn(tr("ข้อความ", "Text")) { Text($0.text.replacingOccurrences(of: "\n", with: " ⏎ ")).lineLimit(1) }
                TableColumn(tr("แป้น", "Keyboard")) { Text(scopeName($0.scope)).foregroundStyle(.secondary) }.width(90)
            }
            .frame(minHeight: 180)
            .padding(.top, 10)
            .onChange(of: picked) { id in
                guard let s = prefs.snippets.first(where: { $0.id == id }) else { return }
                trigger = s.trigger
                text = s.text
                scope = s.scope
                note = ""
            }
            Divider().padding(.vertical, 8)
            HStack {
                TextField(tr("คำย่อ เช่น ;addr", "Trigger, such as ;addr"), text: $trigger).textFieldStyle(.roundedBorder).frame(width: 160)
                Picker("", selection: $scope) {
                    Text(scopeName(2)).tag(Int32(2))
                    Text(scopeName(0)).tag(Int32(0))
                    Text(scopeName(1)).tag(Int32(1))
                    Text(scopeName(3)).tag(Int32(3))
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                .padding(.vertical, 8)
            HStack {
                Menu(tr("วันที่ / เวลา…", "Date / time…")) {
                    ForEach(fields, id: \.0) { f in Button("\(f.0)  \(f.1)") { text += f.0 } }
                    Divider()
                    ForEach(steps, id: \.0) { f in Button("\(f.0)  \(f.1)") { text += f.0 } }
                }
                .fixedSize()
                Text(note).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("ลบ", "Remove")) {
                    guard let picked else { return }
                    prefs.snippets.removeAll { $0.id == picked }
                    self.picked = nil
                    trigger = ""; text = ""
                    note = tr("ลบแล้ว", "Removed")
                }
                .disabled(picked == nil)
                Button(tr("เพิ่ม / บันทึก", "Add / save"), action: save).buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 10)
        }
        Text(tr("คำแนะนำ: ควรขึ้นต้นคำย่อด้วย ; (เช่น ;email) เพื่อไม่ให้ชนกับคำที่พิมพ์จริง · “คำผิดของฉัน” แก้คำที่คุณพิมพ์ผิดประจำเป็นคำที่ถูก (อัตโนมัติ / แก้เมื่อจบคำ) · ใส่ปุ่มลัดได้ เช่น {กด Cmd+B}ตัวหนา{กด Cmd+B}", "Tip: start a trigger with ; (such as ;email) so it never clashes with a real word · “My typo” fixes a word you often mistype (Auto / Semi-auto) · Shortcuts work too, such as {กด Cmd+B}bold{กด Cmd+B}"))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func scopeName(_ s: Int32) -> String {
        [tr("แป้นไทย", "Thai only"), tr("แป้นอังกฤษ", "English only"), tr("ทั้งสองแป้น", "Either"), tr("คำผิดของฉัน", "My typo")][Int(s)]
    }

    private func save() {
        let t = trigger.trimmingCharacters(in: .whitespaces)
        let problem = rt_snippet_check(t, text, scope)
        let messages = [1: tr("คำย่อต้องยาว 2–32 ตัวอักษร", "A trigger is 2 to 32 characters"),
                        2: tr("คำย่อต้องไม่มีช่องว่าง", "A trigger has no spaces"),
                        3: tr("ใส่ข้อความที่ต้องการ", "Write the text it becomes"),
                        4: tr("ข้อความยาวเกินไป (ไม่เกิน 1,000 ตัวอักษร)", "The text is too long (1,000 characters at most)"),
                        5: tr("คำสั่งในวงเล็บปีกกาใช้ไม่ได้ ปุ่มเขียนแบบ {กด Cmd+B} หรือ {กด Enter}",
                              "A command in braces is not right: keys are written {กด Cmd+B} or {กด Enter}"),
                        6: tr("{คำสั่ง …} และ {สไตล์ …} มีเฉพาะบน Windows", "{คำสั่ง …} and {สไตล์ …} are Windows only")]
        if let message = messages[Int(problem)] { note = message; return }
        var list = prefs.snippets
        list.removeAll { $0.trigger == t || $0.id == picked }
        guard list.count < 200 else { note = tr("มีคำย่อได้ไม่เกิน 200 รายการ", "200 snippets at most"); return }
        list.append(Snippet(trigger: t, text: text.replacingOccurrences(of: "\r\n", with: "\n"), scope: scope))
        list.sort { $0.trigger.localizedCompare($1.trigger) == .orderedAscending }
        prefs.snippets = list
        picked = t
        note = tr("บันทึกแล้ว", "Saved")
    }
}

// MARK: Apps

/// Per-app modes and the apps RightType stays out of (`settings.rs`'s Apps
/// page): every app with a mode of its own, and the mode it has.
struct AppsPage: View {
    @ObservedObject var prefs: Prefs
    @State private var picked: Set<String> = []

    var body: some View {
        Text(tr("แต่ละแอปตั้งโหมดของตัวเองได้ แทนโหมดปกติ (\(prefs.mode.name)) โปรแกรมเขียนโค้ดเริ่มที่โหมดกดแก้เอง ชื่อตัวแปรและคำสงวนจะไม่ถูกแก้ระหว่างพิมพ์ กด ⇧⌫ เมื่ออยากแก้คำที่พิมพ์ผิดภาษา", "Each app can have a mode of its own instead of the default (\(prefs.mode.name)). Code editors start in Manual mode, so names and keywords are not changed as you type; press ⇧⌫ to fix a word typed on the wrong keyboard."))
            .foregroundStyle(.secondary)
        Card {
            let apps = prefs.appsWithModes.sorted { appName($0).localizedCompare(appName($1)) == .orderedAscending }
            List(apps, id: \.self, selection: $picked) { id in
                HStack {
                    if let icon = appIcon(id) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        // Not installed here: its bundle ID is all there is.
                        Image(systemName: "app.dashed").frame(width: 18, height: 18).foregroundStyle(.secondary)
                    }
                    Text(appName(id))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { prefs.appMode(id)?.rawValue ?? -1 },
                        set: { prefs.setAppMode(id, $0 < 0 ? nil : Mode(rawValue: $0)) }
                    )) {
                        // The labels of the Windows tray's "ในแอปนี้" submenu.
                        Text(AppDelegate.appModeLabel(nil)).tag(-1)
                        Divider()
                        ForEach([Mode.auto, .suggest, .manual, .semiAuto, .off], id: \.self) { m in
                            Text(AppDelegate.appModeLabel(m)).tag(m.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
            .frame(minHeight: 320)
            .padding(.top, 10)
            HStack {
                Menu(tr("เพิ่มจากแอปที่เปิดอยู่…", "Add open app…")) {
                    ForEach(runningApps(), id: \.0) { app in
                        Button(app.1) { prefs.setAppMode(app.0, .manual) }
                    }
                }
                .fixedSize()
                Button(tr("เพิ่มแอปอื่น…", "Add other app…"), action: pickApp)
                Spacer()
                Button(tr("คืนค่าเริ่มต้น", "Reset")) {
                    prefs.appModes = [:]
                    prefs.excluded = Array(defaultExcluded)
                }
                Button(tr("ลบออก", "Remove")) {
                    for id in picked {
                        prefs.excluded.removeAll { $0 == id }
                        prefs.appModes[id] = codeEditors.contains(id) ? -1 : nil
                    }
                    picked = []
                }
                .disabled(picked.isEmpty)
            }
            .padding(.vertical, 10)
        }
        Text(tr("แอปที่เพิ่มใหม่เริ่มที่โหมดกดแก้เอง เปลี่ยนได้จากเมนูท้ายแถว · RightType ยกเว้นช่องรหัสผ่านเสมอ (macOS ไม่ส่งปุ่มให้แอปไหนดักได้) · ตั้งโหมดของแอปที่ใช้อยู่ได้จากเมนู Aก หรือ ⌃⌥Space ด้วย", "An app added here starts in Manual mode; change it from the menu at the end of its row · Password fields are always left alone (macOS passes their keys to no app) · The app you are in can be set from the Aก menu or ⌃⌥Space too"))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func runningApps() -> [(String, String)] {
        let listed = Set(prefs.appsWithModes)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { $0.0 != Bundle.main.bundleIdentifier && !listed.contains($0.0) }
            .sorted { $0.1.localizedCompare($1.1) == .orderedAscending }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
              !prefs.appsWithModes.contains(id) else { return }
        prefs.setAppMode(id, .manual)
    }
}

func appURL(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

func appName(_ id: String) -> String {
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName {
        return running
    }
    return appURL(id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
}

func appIcon(_ id: String) -> NSImage? {
    appURL(id).map { NSWorkspace.shared.icon(forFile: $0.path) }
}

// MARK: Privacy

struct PrivacyPage: View {
    var body: some View {
        Heading(title: tr("ความเป็นส่วนตัว", "Privacy"), icon: "lock")
        Card {
            item("wifi.slash", tr("ไม่ต่ออินเทอร์เน็ต", "Never connects to the internet"),
                 tr("ทุกอย่างทำงานบนเครื่องคุณ ไม่มีโค้ดเครือข่าย ไม่มีการส่งข้อมูลออก", "Everything runs on your Mac. There is no network code and nothing is sent anywhere."))
            Divider()
            item("eye.slash", tr("ไม่เก็บข้อความที่พิมพ์", "Keeps no typed text"),
                 tr("เก็บแค่คำที่กำลังพิมพ์ในหน่วยความจำแล้วล้างทิ้ง ช่องรหัสผ่านและแอปในรายการที่ไม่ใช้จะถูกข้าม", "Only the word being typed is held in memory, then wiped. Password fields and ignored apps are skipped."))
            Divider()
            item("trash", tr("ล้างข้อมูลที่จำไว้ได้ทุกเมื่อ", "Clear remembered data anytime"),
                 tr("สิ่งเดียวที่บันทึกลงดิสก์คือคำที่จำไว้และคำย่อที่คุณตั้งเอง ดูและลบได้ที่หน้า “คำที่จำไว้” และ “คำย่อ”", "The only things saved to disk are learned words and your snippets. See and remove them on the “Learned words” and “Snippets” pages."))
        }
        Heading(title: tr("เกี่ยวกับ", "About"), icon: "info.circle")
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("RightType \(version) สำหรับ macOS", "RightType \(version) for macOS"))
                Text(tr("พอร์ตจาก RightType ของ Windows ใช้แกน Rust ตัวเดียวกัน (ดิกชันนารีและกฎเดียวกัน)", "A port of RightType for Windows, on the same Rust core (the same dictionaries and rules)."))
                    .font(.callout).foregroundStyle(.secondary)
                Text(tr("ซอฟต์แวร์ฟรี ภายใต้ MIT หรือ Apache-2.0", "Free software under MIT or Apache-2.0")).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Link(tr("RightType ต้นฉบับบน GitHub", "The original RightType on GitHub"), destination: URL(string: "https://github.com/k-affan-th/RightType")!)
                    Text("·").foregroundStyle(.secondary)
                    Link(tr("ดาวน์โหลดเวอร์ชันใหม่", "Download the latest version"), destination: URL(string: "https://github.com/soraxtend/right-type-mac/releases")!)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 12)
        }
    }

    private func item(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }
}
