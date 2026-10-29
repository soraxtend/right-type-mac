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

    func show(page: SettingsPage? = nil) {
        if let page { nav.page = page }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "RightType — ตั้งค่า"
            w.contentView = NSHostingView(rootView: SettingsView(nav: nav, prefs: Prefs.shared))
            w.contentMinSize = NSSize(width: 700, height: 520)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
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
    case general, keyboard, tools, hotkeys, learned, snippets, apps, privacy, support
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "ทั่วไป"
        case .keyboard: return "แป้นพิมพ์"
        case .tools: return "เครื่องมือ"
        case .hotkeys: return "ปุ่มลัด"
        case .learned: return "คำที่จำไว้"
        case .snippets: return "คำย่อ"
        case .apps: return "แอปที่ไม่ใช้"
        case .privacy: return "ความเป็นส่วนตัว"
        case .support: return "สนับสนุน"
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
        case .support: return "heart"
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
            Text("พิมพ์ผิดภาษา แก้ให้เอง").font(.caption).foregroundStyle(.secondary).padding(.bottom, 14)
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
            Text("เวอร์ชัน \(version)").font(.caption).foregroundStyle(.secondary)
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
        case .support: SupportPage()
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
        Heading(title: "วิธีแก้คำ", icon: "slider.horizontal.3")
        Card {
            Picker("", selection: $prefs.mode) {
                Label("อัตโนมัติ", systemImage: "bolt").tag(Mode.auto)
                Label("แนะนำ", systemImage: "lightbulb").tag(Mode.suggest)
                Label("แก้เมื่อจบคำ", systemImage: "space").tag(Mode.semiAuto)
                Label("กดแก้เอง", systemImage: "keyboard").tag(Mode.manual)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.top, 10)
            Text(prefs.mode.detail).font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
        }
        Heading(title: "การทำงาน", icon: "gearshape")
        Card {
            ToggleRow(icon: "power", title: "เปิดใช้งาน RightType",
                      detail: "เปิดหรือปิดได้ทุกเมื่อจากเมนูบาร์หรือ ⌃⌥Space", on: $prefs.enabled)
            ToggleRow(icon: "play", title: "เปิดพร้อม macOS",
                      detail: "ทำงานเงียบ ๆ ที่เมนูบาร์เมื่อเข้าสู่ระบบ", on: Binding(get: { login }, set: setLogin))
            ToggleRow(icon: "book", title: "เรียนรู้คำใหม่",
                      detail: "จำคำภาษาอังกฤษที่คุณพิมพ์บ่อย (3 ครั้ง) เก็บในเครื่องนี้เท่านั้น", on: $prefs.learnTyped)
            ToggleRow(icon: "arrow.uturn.backward", title: "จำคำที่แก้กลับ",
                      detail: "กด ⇧⌫ ย้อนคำที่ RightType แก้ให้ แปลว่าคำเดิมถูกแล้ว ครั้งหน้าจะไม่แก้อีก", on: $prefs.learnReversed)
            ToggleRow(icon: "cursorarrow.rays", title: "แสดงป้ายข้างเคอร์เซอร์",
                      detail: "คำแนะนำของโหมดแนะนำ (กด Tab เพื่อใช้) และข้อความหลังแก้คำ", on: $prefs.hints)
            ToggleRow(icon: "character.book.closed", title: "แก้คำไทยที่สะกดผิดบ่อย",
                      detail: "แก้คำสะกดผิดที่พบบ่อยราว 60 คำ เมื่อจบคำ (อัตโนมัติ / แก้เมื่อจบคำ)", on: $prefs.spelling, last: true)
            Divider()
            HStack {
                Text("คำที่เรียนรู้แล้ว: \(prefs.learnedVersion >= 0 ? prefs.learnedCount : 0)").foregroundStyle(.secondary)
                Spacer()
                Button { nav.page = .learned } label: { Label("แก้ไข…", systemImage: "pencil") }
            }
            .padding(.vertical, 10)
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Tap.shared.onNote?("ตั้งค่าไม่สำเร็จ: \(error.localizedDescription)")
        }
        login = SMAppService.mainApp.status == .enabled
    }
}

// MARK: Keyboard

struct KeyboardPage: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        Heading(title: "แป้นพิมพ์ที่ใช้", icon: "keyboard")
        Card {
            let sources = InputSources.enabledSummary
            row("ไทย", sources.thai.isEmpty ? "ยังไม่ได้เพิ่ม — เพิ่ม Thai (เกษมณี) ใน System Settings" : sources.thai.joined(separator: ", "),
                ok: !sources.thai.isEmpty)
            Divider()
            row("อังกฤษ", sources.english.isEmpty ? "ยังไม่มี — เพิ่ม ABC หรือ U.S." : sources.english.joined(separator: ", "),
                ok: !sources.english.isEmpty)
            if !sources.other.isEmpty {
                Divider()
                row("ไม่ยุ่ง", sources.other.joined(separator: ", "), ok: true)
            }
            Divider()
            HStack {
                Text("RightType ดูว่าคีย์บอร์ดเป็นไทยหรืออังกฤษจากตัวอักษรที่แต่ละปุ่มพิมพ์ ไม่ได้ดูจากชื่อ")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("เปิดการตั้งค่าคีย์บอร์ด…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }
            .padding(.vertical, 10)
        }
        Heading(title: "ระหว่างพิมพ์", icon: "text.cursor")
        Card {
            ToggleRow(icon: "at", title: "ที่อยู่เว็บ อีเมล และตัวเลข",
                      detail: "พิมพ์ตอนแป้นไทยเปิดอยู่ แก้กลับให้ เช่น name@gmail.com, www.…, 100, 10:30", on: $prefs.addresses)
            ToggleRow(icon: "character.book.closed", title: "แก้คำไทยที่สะกดผิดบ่อย",
                      detail: "เช่น อนุญาติ → อนุญาต และอีกราว 60 คำ", on: $prefs.spelling, last: true)
        }
    }

    private func row(_ title: String, _ value: String, ok: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(title).frame(width: 70, alignment: .leading)
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

    private let transforms: [(String, Int32)] = [
        ("แก้เฉพาะคำที่พิมพ์ผิดแป้น", RT_TRANSFORM_REPAIR), ("สลับภาษาทั้งหมด", RT_TRANSFORM_FLIP),
        ("จัดอักษรไทยเป็นมาตรฐาน", RT_TRANSFORM_NORMALIZE), ("จัดเว้นวรรคแบบไทย", RT_TRANSFORM_SPACING),
        ("ปี พ.ศ. ↔ ค.ศ.", RT_TRANSFORM_ERA), ("ตัวเลขเป็นคำอ่าน", RT_TRANSFORM_NUMBER_WORDS),
        ("จำนวนเงินเป็นตัวอักษร (บาท)", RT_TRANSFORM_BAHT_WORDS), ("เลขไทย ↔ เลขอารบิก", RT_TRANSFORM_DIGITS),
        ("ตัวพิมพ์ใหญ่ทั้งหมด", RT_TRANSFORM_UPPER), ("ตัวพิมพ์เล็กทั้งหมด", RT_TRANSFORM_LOWER),
        ("ขึ้นต้นคำด้วยตัวใหญ่", RT_TRANSFORM_TITLE), ("สลับตัวเล็ก/ใหญ่", RT_TRANSFORM_SWAP_CASE),
    ]

    var body: some View {
        Heading(title: "ซ่อมข้อความ", icon: "doc.text")
        Card {
            Text("วางข้อความที่พิมพ์ผิดแป้น แล้วกดแก้ คำที่พิมพ์ผิดภาษาจะถูกแก้ ที่เหลือคงเดิม")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 10)
            TextEditor(text: $text)
                .font(.system(size: 14))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                .padding(.vertical, 8)
            HStack {
                Button("แก้") { apply(RT_TRANSFORM_REPAIR) }.keyboardShortcut(.defaultAction)
                Button("วางแล้วแก้") {
                    text = NSPasteboard.general.string(forType: .string) ?? ""
                    apply(RT_TRANSFORM_REPAIR)
                }
                Menu("เปลี่ยนแบบอื่น") {
                    ForEach(transforms, id: \.1) { t in Button(t.0) { apply(t.1) } }
                }
                .fixedSize()
                Spacer()
                Text(note).font(.caption).foregroundStyle(.secondary)
                Button("คัดลอก") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    note = "คัดลอกแล้ว"
                }
            }
            .padding(.bottom, 10)
        }
        Heading(title: "ข้อความที่เลือกในแอปอื่น", icon: "selection.pin.in.out")
        Card {
            Text("เลือกข้อความในแอปไหนก็ได้ แล้วกด ⌃⇧⌫ เพื่อแก้คำที่พิมพ์ผิดแป้น หรือกด ⌃⌥Space แล้วเลือกจากหมวด “ข้อความที่เลือก” (ตัวพิมพ์ใหญ่ ปี พ.ศ. จำนวนเงินเป็นตัวอักษร ฯลฯ)")
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
        }
    }

    private func apply(_ kind: Int32) {
        guard !text.isEmpty, let out = takeString(rt_transform(kind, text)) else { return }
        note = out == text ? "ไม่มีอะไรต้องเปลี่ยน" : "แก้แล้ว"
        text = out
    }
}

// MARK: Hotkeys

struct HotkeysPage: View {
    private let keys: [(String, String)] = [
        ("⇧⌫", "แก้คำล่าสุดในที่เดิม กดซ้ำเพื่อแก้ย้อนไปได้ถึง 8 คำ กดอีกทีหลังแก้ครบเพื่อย้อนกลับทั้งหมด"),
        ("⌃⇧⌫", "แก้ข้อความที่เลือกอยู่ (ใช้คลิปบอร์ดชั่วคราว แล้วคืนของเดิมให้)"),
        ("Tab", "ใช้คำแนะนำของโหมดแนะนำ (ภายใน 4 วินาที)"),
        ("⌃⌥Space", "Command palette: แก้ข้อความ, เปลี่ยนข้อความที่เลือก, โหมด, หยุดชั่วคราว, ปิดในแอปนี้ และอื่น ๆ"),
    ]

    var body: some View {
        Heading(title: "ปุ่มลัด", icon: "bolt")
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
        Text("บน Mac ใช้ ⇧⌫ (Shift+Delete) แทน Shift+Backspace ของ Windows ปุ่มที่ใช้ CapsLock บน Windows ย้ายมาอยู่ใน ⌃⌥Space")
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
        Text("คำที่ RightType จะไม่แก้ ปล่อยไว้ตามที่พิมพ์ เพิ่มคำได้ด้วยตัวเอง หรือให้ RightType จำเองเมื่อคุณกด ⇧⌫ ย้อนคำที่มันแก้")
            .foregroundStyle(.secondary)
        Card {
            HStack {
                TextField("คำใหม่ เช่น kubernetes หรือ ต๊าช", text: $word)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit(add)
                Button("เพิ่ม", action: add).buttonStyle(.borderedProminent)
                Spacer()
                Button("ลบ") {
                    guard !picked.isEmpty else { note = "เลือกคำในรายการก่อน"; return }
                    prefs.replaceLearned(words.filter { !picked.contains($0) })
                    picked = []
                }
            }
            .padding(.vertical, 10)
            List(words, id: \.self, selection: $picked) { Text($0) }
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
            HStack {
                Button("นำเข้า…", action: importFile)
                Button("ส่งออก…") { exportFile(words) }
                Text(note).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("ล้างทั้งหมด", role: .destructive) { confirmClear() }
            }
            .padding(.vertical, 10)
        }
        HStack {
            Text("\(words.count) คำ · บันทึกไว้ในเครื่องนี้เท่านั้น").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("เปิดตำแหน่งไฟล์") {
                NSWorkspace.shared.activateFileViewerSelecting([prefs.learnedFile()])
            }
        }
    }

    private func add() {
        guard !word.isEmpty else { return }
        if let learned = prefs.learn(word) { note = "เพิ่ม “\(learned)” แล้ว"; word = "" } else { note = "เพิ่มคำนี้ไม่ได้" }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let before = prefs.learnedWords
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let skipped = prefs.replaceLearned(before + lines)
        let added = prefs.learnedCount - before.count
        note = skipped > 0 ? "เพิ่ม \(added) คำจากไฟล์แล้ว ข้าม \(skipped) บรรทัดที่ไม่ใช่คำเดียว" : "เพิ่ม \(added) คำจากไฟล์แล้ว"
    }

    private func exportFile(_ words: [String]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RightType learned words.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? (words.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        note = "บันทึก \(words.count) คำลงไฟล์แล้ว"
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "ล้างคำที่จำไว้ทั้งหมด?"
        alert.informativeText = "RightType จะลืมทุกคำที่เรียนรู้มา ย้อนไม่ได้"
        alert.addButton(withTitle: "ล้างทั้งหมด")
        alert.addButton(withTitle: "ยกเลิก")
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
        ("{กด Cmd+B}", "กดปุ่มลัด"), ("{รอ 300}", "รอ 300 มิลลิวินาที"), ("{คลิปบอร์ด}", "พิมพ์ข้อความที่คัดลอก"),
    ]

    var body: some View {
        Text("พิมพ์คำย่อแล้วกด Space หรือ Enter เพื่อแปลงเป็นข้อความเต็ม").foregroundStyle(.secondary)
        Card {
            Table(prefs.snippets, selection: $picked) {
                TableColumn("คำย่อ") { Text($0.trigger).font(.system(.body, design: .monospaced)) }.width(110)
                TableColumn("ข้อความ") { Text($0.text.replacingOccurrences(of: "\n", with: " ⏎ ")).lineLimit(1) }
                TableColumn("แป้น") { Text(scopeName($0.scope)).foregroundStyle(.secondary) }.width(90)
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
                TextField("คำย่อ เช่น ;addr", text: $trigger).textFieldStyle(.roundedBorder).frame(width: 160)
                Picker("", selection: $scope) {
                    Text("ทั้งสองแป้น").tag(Int32(2))
                    Text("แป้นไทย").tag(Int32(0))
                    Text("แป้นอังกฤษ").tag(Int32(1))
                    Text("คำผิดของฉัน").tag(Int32(3))
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                .padding(.vertical, 8)
            HStack {
                Menu("วันที่ / เวลา…") {
                    ForEach(fields, id: \.0) { f in Button("\(f.0)  \(f.1)") { text += f.0 } }
                    Divider()
                    ForEach(steps, id: \.0) { f in Button("\(f.0)  \(f.1)") { text += f.0 } }
                }
                .fixedSize()
                Text(note).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("ลบ") {
                    guard let picked else { return }
                    prefs.snippets.removeAll { $0.id == picked }
                    self.picked = nil
                    trigger = ""; text = ""
                    note = "ลบแล้ว"
                }
                .disabled(picked == nil)
                Button("เพิ่ม / บันทึก", action: save).buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 10)
        }
        Text("คำแนะนำ: ควรขึ้นต้นคำย่อด้วย ; (เช่น ;email) เพื่อไม่ให้ชนกับคำที่พิมพ์จริง · “คำผิดของฉัน” แก้คำที่คุณพิมพ์ผิดประจำเป็นคำที่ถูก (อัตโนมัติ / แก้เมื่อจบคำ) · ใส่ปุ่มลัดได้ เช่น {กด Cmd+B}ตัวหนา{กด Cmd+B}")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func scopeName(_ s: Int32) -> String {
        ["แป้นไทย", "แป้นอังกฤษ", "ทั้งสองแป้น", "คำผิดของฉัน"][Int(s)]
    }

    private func save() {
        let t = trigger.trimmingCharacters(in: .whitespaces)
        let problem = rt_snippet_check(t, text, scope)
        let messages = [1: "คำย่อต้องยาว 2–32 ตัวอักษร", 2: "คำย่อต้องไม่มีช่องว่าง", 3: "ใส่ข้อความที่ต้องการ",
                        4: "ข้อความยาวเกินไป (ไม่เกิน 1,000 ตัวอักษร)",
                        5: "คำสั่งในวงเล็บปีกกาใช้ไม่ได้ ปุ่มเขียนแบบ {กด Cmd+B} หรือ {กด Enter}",
                        6: "{คำสั่ง …} และ {สไตล์ …} มีเฉพาะบน Windows"]
        if let message = messages[Int(problem)] { note = message; return }
        var list = prefs.snippets
        list.removeAll { $0.trigger == t || $0.id == picked }
        guard list.count < 200 else { note = "มีคำย่อได้ไม่เกิน 200 รายการ"; return }
        list.append(Snippet(trigger: t, text: text.replacingOccurrences(of: "\r\n", with: "\n"), scope: scope))
        list.sort { $0.trigger.localizedCompare($1.trigger) == .orderedAscending }
        prefs.snippets = list
        picked = t
        note = "บันทึกแล้ว"
    }
}

// MARK: Apps

/// Per-app modes and the apps RightType stays out of (`settings.rs`'s Apps
/// page): every app with a mode of its own, and the mode it has.
struct AppsPage: View {
    @ObservedObject var prefs: Prefs
    @State private var picked: Set<String> = []

    var body: some View {
        Text("แต่ละแอปตั้งโหมดของตัวเองได้ แทนโหมดปกติ (\(prefs.mode.name)) โปรแกรมเขียนโค้ดเริ่มที่โหมดกดแก้เอง ชื่อตัวแปรและคำสงวนจะไม่ถูกแก้ระหว่างพิมพ์ กด ⇧⌫ เมื่ออยากแก้คำที่พิมพ์ผิดภาษา")
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
                        Text("ใช้โหมดปกติ").tag(-1)
                        Divider()
                        ForEach([Mode.auto, .suggest, .manual, .semiAuto, .off], id: \.self) { m in
                            Text(m == .off ? "ปิดในแอปนี้" : "โหมด\(m.name)")
                                .tag(m.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
            .frame(minHeight: 320)
            .padding(.top, 10)
            HStack {
                Menu("เพิ่มจากแอปที่เปิดอยู่…") {
                    ForEach(runningApps(), id: \.0) { app in
                        Button(app.1) { prefs.setAppMode(app.0, .manual) }
                    }
                }
                .fixedSize()
                Button("เพิ่มแอปอื่น…", action: pickApp)
                Spacer()
                Button("คืนค่าเริ่มต้น") {
                    prefs.appModes = [:]
                    prefs.excluded = Array(defaultExcluded)
                }
                Button("ลบออก") {
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
        Text("แอปที่เพิ่มใหม่เริ่มที่โหมดกดแก้เอง เปลี่ยนได้จากเมนูท้ายแถว · RightType ยกเว้นช่องรหัสผ่านเสมอ (macOS ไม่ส่งปุ่มให้แอปไหนดักได้) · ตั้งโหมดของแอปที่ใช้อยู่ได้จากเมนู Aก หรือ ⌃⌥Space ด้วย")
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
        Heading(title: "ความเป็นส่วนตัว", icon: "lock")
        Card {
            item("wifi.slash", "ไม่ต่ออินเทอร์เน็ต", "ทุกอย่างทำงานบนเครื่องคุณ ไม่มีโค้ดเครือข่าย ไม่มีการส่งข้อมูลออก")
            Divider()
            item("eye.slash", "ไม่เก็บข้อความที่พิมพ์", "เก็บแค่คำที่กำลังพิมพ์ในหน่วยความจำแล้วล้างทิ้ง ช่องรหัสผ่านและแอปในรายการที่ไม่ใช้จะถูกข้าม")
            Divider()
            item("trash", "ล้างข้อมูลที่จำไว้ได้ทุกเมื่อ", "สิ่งเดียวที่บันทึกลงดิสก์คือคำที่จำไว้และคำย่อที่คุณตั้งเอง ดูและลบได้ที่หน้า “คำที่จำไว้” และ “คำย่อ”")
        }
        Heading(title: "เกี่ยวกับ", icon: "info.circle")
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("RightType \(version) สำหรับ macOS")
                Text("พอร์ตจาก RightType ของ Windows ใช้แกน Rust ตัวเดียวกัน (ดิกชันนารีและกฎเดียวกัน)")
                    .font(.callout).foregroundStyle(.secondary)
                Text("ซอฟต์แวร์ฟรี ภายใต้ MIT หรือ Apache-2.0").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Link("RightType ต้นฉบับบน GitHub", destination: URL(string: "https://github.com/k-affan-th/RightType")!)
                    Text("·").foregroundStyle(.secondary)
                    Link("ดาวน์โหลดเวอร์ชันใหม่", destination: URL(string: "https://github.com/k-affan-th/RightType/releases")!)
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

// MARK: Support

struct SupportPage: View {
    var body: some View {
        Heading(title: "สนับสนุน RightType", icon: "heart")
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("RightType เป็นซอฟต์แวร์ฟรีและโอเพนซอร์ส ถ้าช่วยให้คุณพิมพ์ได้สบายขึ้น ช่วยได้หลายทาง: กดดาวให้โปรเจกต์ แจ้งปัญหาหรือคำที่แก้ผิด หรือสนับสนุนผู้พัฒนาต้นฉบับผ่านช่องทางในหน้า GitHub")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("เปิด GitHub") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/k-affan-th/RightType")!)
                    }
                    Button("แจ้งปัญหา") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/k-affan-th/RightType/issues")!)
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }
}
