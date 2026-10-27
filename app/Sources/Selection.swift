import AppKit

/// Fix the text selected in the frontmost app: copy it, fix it, paste it
/// back, then put the clipboard back as it was.
enum Selection {
    static func fix() {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        Inject.key(Keys.c, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard pb.changeCount != before, let text = pb.string(forType: .string), !text.isEmpty else {
                Tap.shared.onNote?("ไม่มีข้อความที่เลือก")
                return
            }
            guard let fixedPtr = rt_repair(text) else { return }
            let fixed = String(cString: fixedPtr)
            rt_string_free(fixedPtr)
            pb.clearContents()
            pb.setString(fixed, forType: .string)
            Inject.key(Keys.v, flags: .maskCommand)
            Tap.shared.reset(all: true)
            let thai = fixed.unicodeScalars.reversed().first { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }
                .map { (0x0E00...0x0E7F).contains($0.value) } ?? false
            InputSources.select(thai ? RT_LAYOUT_THAI : RT_LAYOUT_ENGLISH)
            Tap.shared.onNote?("แก้ข้อความที่เลือกแล้ว")
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
