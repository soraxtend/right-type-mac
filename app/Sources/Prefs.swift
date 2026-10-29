import AppKit
import Combine

/// One snippet as the settings keep it (`righttype::snippets::Snippet`).
struct Snippet: Codable, Hashable, Identifiable {
    var trigger: String
    var text: String
    /// 0 Thai, 1 English, 2 either keyboard, 3 a misspelling of your own.
    var scope: Int32

    var id: String { trigger }
}

/// Apps RightType stays out of unless the user says otherwise: terminals,
/// password managers and remote desktops, where retyping keys is unwelcome.
let defaultExcluded: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    "com.apple.keychainaccess", "com.apple.Passwords",
    "com.microsoft.rdc.macos", "com.apple.ScreenSharing", "com.realvnc.vncviewer",
]

/// Code editors (`code::CODE_EDITORS` on Windows): Manual by default there,
/// so names and keywords are never rewritten as they are typed. Any of them
/// can be given another mode.
let codeEditors: Set<String> = [
    "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", // Cursor
    "com.exafunction.windsurf", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4", "com.sublimetext.3",
    "com.panic.Nova", "com.barebones.bbedit", "org.vim.MacVim", "com.google.android.studio",
    "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
    "com.jetbrains.WebStorm", "com.jetbrains.CLion", "com.jetbrains.goland", "com.jetbrains.rider",
    "com.jetbrains.PhpStorm", "com.jetbrains.rubymine", "com.jetbrains.datagrip", "com.jetbrains.rustrover",
    "com.jetbrains.fleet", "com.vscodium", "com.trae.app", "com.google.antigravity", "org.gnu.Emacs",
]

/// Every setting, kept in UserDefaults, applied to the tap and the core the
/// moment it changes (as the Windows settings window does: no Apply button).
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { save("enabled", enabled) } }
    /// The correction mode while enabled (never `.off`).
    @Published var mode: Mode { didSet { save("mode", mode.rawValue) } }
    /// Learn words flipped back with Shift+Backspace.
    @Published var learnReversed: Bool { didSet { save("learnReversed", learnReversed) } }
    /// Learn English words typed three times.
    @Published var learnTyped: Bool { didSet { save("learnTyped", learnTyped) } }
    /// Hints by the caret (Suggest) and messages after a fix.
    @Published var hints: Bool { didSet { save("hints", hints) } }
    @Published var spelling: Bool { didSet { save("spelling", spelling) } }
    @Published var addresses: Bool { didSet { save("addresses", addresses) } }
    @Published var excluded: [String] { didSet { save("excluded", excluded) } }
    /// Apps with a mode of their own (bundle ID → `Mode` raw value, or -1: a
    /// code editor set to follow the global mode). "Off" lives in `excluded`.
    @Published var appModes: [String: Int] { didSet { save("appModes", appModes) } }
    @Published var snippets: [Snippet] {
        didSet {
            defaults.set(try? JSONEncoder().encode(snippets), forKey: "snippets")
            applySnippets()
        }
    }
    /// Paused until then (the palette's "pause for 30 minutes").
    @Published var pausedUntil: Date?
    /// Bumped when the learned words change, so pages showing them redraw.
    @Published var learnedVersion = 0
    /// The interface language (`i18n::Lang` on Windows): 0 follows macOS,
    /// 1 Thai, 2 English.
    @Published var language: Int { didSet { save("language", language) } }

    private init() {
        defaults.register(defaults: [
            "enabled": true, "mode": Mode.auto.rawValue, "learnReversed": true, "learnTyped": false,
            "hints": true, "spelling": false, "addresses": true, "excluded": Array(defaultExcluded),
        ])
        var stored = Mode(rawValue: defaults.integer(forKey: "mode")) ?? .auto
        var enabled = defaults.bool(forKey: "enabled")
        if stored == .off {
            // 0.1.x kept "off" as a mode.
            stored = .auto
            enabled = false
        }
        self.enabled = enabled
        mode = stored
        learnReversed = defaults.bool(forKey: "learnReversed")
        learnTyped = defaults.bool(forKey: "learnTyped")
        hints = defaults.bool(forKey: "hints")
        spelling = defaults.bool(forKey: "spelling")
        addresses = defaults.bool(forKey: "addresses")
        excluded = defaults.stringArray(forKey: "excluded") ?? Array(defaultExcluded)
        appModes = defaults.dictionary(forKey: "appModes") as? [String: Int] ?? [:]
        snippets = defaults.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        language = defaults.integer(forKey: "language")
    }

    /// Load the learned words and hand every setting to the core.
    func start() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RightType", isDirectory: true)
        rt_learn_open(learnedFile(in: dir).path)
        applyAll()
        applySnippets()
    }

    func learnedFile(in dir: URL? = nil) -> URL {
        let base = dir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RightType", isDirectory: true)
        return base.appendingPathComponent("learned.txt")
    }

    /// The mode the tap works in now, in `app`.
    func mode(for app: String) -> Mode {
        Self.resolve(app, enabled: enabled, paused: paused, global: mode, excluded: excluded, appModes: appModes)
    }

    /// The mode `app` has of its own (nil: it follows the global mode).
    func appMode(_ app: String) -> Mode? {
        Self.own(app, excluded: excluded, appModes: appModes)
    }

    /// `mode(for:)` from the settings alone (the self-test checks the rules).
    static func resolve(_ app: String, enabled: Bool, paused: Bool, global: Mode,
                        excluded: [String], appModes: [String: Int]) -> Mode {
        if !enabled || paused { return .off }
        return own(app, excluded: excluded, appModes: appModes) ?? global
    }

    static func own(_ app: String, excluded: [String], appModes: [String: Int]) -> Mode? {
        if excluded.contains(app) { return .off }
        // 5 was Code mode in 0.2.0: Manual is what it is closest to.
        if let raw = appModes[app] { return raw < 0 ? nil : Mode(rawValue: raw) ?? .manual }
        return codeEditors.contains(app) ? .manual : nil
    }

    /// Give `app` a mode of its own (`.off` keeps out of it), or nil to
    /// follow the global mode (for a code editor too).
    func setAppMode(_ app: String, _ mode: Mode?) {
        excluded.removeAll { $0 == app }
        switch mode {
        case .off?: excluded.append(app); appModes[app] = nil
        case let m?: appModes[app] = m.rawValue
        case nil: appModes[app] = codeEditors.contains(app) ? -1 : nil
        }
    }

    /// Apps with a mode of their own, for the settings page: the ones set
    /// here, the code editors installed, and the apps kept out of.
    var appsWithModes: [String] {
        let installed = codeEditors.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return Array(Set(excluded).union(appModes.keys).union(installed))
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        applyAll()
    }

    private func applyAll() {
        rt_learn_set(learnReversed, learnTyped)
        Tap.shared.applyOptions(spelling: spelling, addresses: addresses)
        Tap.shared.excluded = Set(excluded)
        Tap.shared.reset(all: true)
        NotificationCenter.default.post(name: .rightTypeStateChanged, object: nil)
    }

    private func applySnippets() {
        Tap.shared.setSnippets(snippets)
    }

    func pause(minutes: Int) {
        pausedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        Tap.shared.reset(all: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(minutes * 60) + 0.5) { [weak self] in
            if let until = self?.pausedUntil, until <= Date() { self?.resume() }
        }
        NotificationCenter.default.post(name: .rightTypeStateChanged, object: nil)
    }

    func resume() {
        pausedUntil = nil
        NotificationCenter.default.post(name: .rightTypeStateChanged, object: nil)
    }

    var paused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    // MARK: Learned words

    var learnedWords: [String] {
        guard let p = rt_learn_list() else { return [] }
        defer { rt_string_free(p) }
        return String(cString: p).split(separator: "\n").map(String.init)
    }

    var learnedCount: Int { Int(rt_learn_count()) }

    /// Make `words` the whole list; returns how many lines were not a word.
    @discardableResult
    func replaceLearned(_ words: [String]) -> Int {
        var kept: UInt32 = 0
        let skipped = rt_learn_replace(words.joined(separator: "\n"), &kept)
        learnedVersion += 1
        return Int(skipped)
    }

    /// Learn `word`; returns it as learned, or nil when it is not one word.
    func learn(_ word: String) -> String? {
        guard let p = rt_learn_add(word) else { return nil }
        defer { rt_string_free(p) }
        learnedVersion += 1
        return String(cString: p)
    }

    func clearLearned() {
        rt_learn_clear()
        learnedVersion += 1
    }
}

extension Notification.Name {
    /// The mode, pause or enabled state changed: the menu bar icon follows.
    static let rightTypeStateChanged = Notification.Name("RightTypeStateChanged")
}

/// The self-test and `--render-settings` pick the language themselves.
var uiThaiOverride: Bool?

/// Thai for the interface? Following macOS, Thai when Thai is anywhere in
/// the preferred languages: whoever types Thai reads it, though many keep
/// macOS itself in English.
var uiThai: Bool {
    if let uiThaiOverride { return uiThaiOverride }
    switch Prefs.shared.language {
    case 1: return true
    case 2: return false
    default: return Locale.preferredLanguages.contains { $0.hasPrefix("th") }
    }
}

/// `th` or `en`, in the interface language.
func tr(_ th: String, _ en: String) -> String { uiThai ? th : en }

/// A string the core returned, released.
func takeString(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { rt_string_free(p) }
    return String(cString: p)
}
