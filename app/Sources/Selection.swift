import AppKit

/// The text selected in the frontmost app: read and changed by copying it
/// and pasting the result over it, then putting the clipboard back.
enum Selection {
    /// Fix the words typed on the wrong keyboard (or flip the whole text).
    static func fix() {
        transform(note: tr("แก้ข้อความที่เลือกแล้ว", "Fixed the selected text")) { takeString(rt_repair($0)) }
    }

    /// Change the selection with one of the core's transforms (`RT_TRANSFORM_*`).
    static func transform(_ kind: Int32, note: String) {
        transform(note: note) { takeString(rt_transform(kind, $0)) }
    }

    /// The selected text, read by copying it (the clipboard is put back).
    static func read(_ done: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        Inject.key(Keys.c, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let text = pb.changeCount != before ? pb.string(forType: .string) : nil
            restore(pb, saved)
            done(text?.isEmpty == false ? text : nil)
        }
    }

    /// Copy the selection, change it with `change`, paste the result over it,
    /// then put the clipboard back as it was.
    static func transform(note: String, _ change: @escaping (String) -> String?) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        Inject.key(Keys.c, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard pb.changeCount != before, let text = pb.string(forType: .string), !text.isEmpty else {
                Tap.shared.onNote?(tr("ไม่มีข้อความที่เลือก", "No text is selected"))
                return
            }
            guard let fixed = change(text) else { return }
            if fixed == text {
                restore(pb, saved)
                Tap.shared.onNote?(tr("ไม่มีอะไรต้องเปลี่ยน", "Nothing to change"))
                return
            }
            pb.clearContents()
            pb.setString(fixed, forType: .string)
            Inject.key(Keys.v, flags: .maskCommand)
            Tap.shared.reset(all: true)
            let thai = fixed.unicodeScalars.reversed().first { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }
                .map { (0x0E00...0x0E7F).contains($0.value) } ?? false
            InputSources.select(thai ? RT_LAYOUT_THAI : RT_LAYOUT_ENGLISH)
            Tap.shared.onNote?(note)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { restore(pb, saved) }
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { types[t] = d } }
            return types
        }
    }

    private static func restore(_ pb: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        let items = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
