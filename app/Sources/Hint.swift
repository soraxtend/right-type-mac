import AppKit
import ApplicationServices

/// Suggest's hint: the word as it would be fixed, in a small tag by the text
/// cursor (`overlay::show_at` at `caret::hint_anchor` on Windows). Gone with
/// the next key.
final class Hint {
    static let shared = Hint()
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 28),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView()
        bg.material = .toolTip
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 7
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        panel.contentView = bg
    }

    func show(_ text: String) {
        label.stringValue = text
        let size = NSSize(width: label.intrinsicContentSize.width + 22, height: 28)
        let origin: NSPoint
        if let caret = Self.caretRect() {
            // Just under the line being typed.
            origin = NSPoint(x: caret.minX, y: caret.minY - size.height - 4)
        } else {
            // No caret to read (some apps do not say): near the pointer.
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        hideWork?.cancel()
        // Tab takes it only for a few seconds.
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    var isVisible: Bool { panel.isVisible }

    func hide() {
        guard panel.isVisible else { return }
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    /// The focused element, with a short timeout: these calls run on the
    /// thread that delivers keystrokes, and a slow app (VS Code, say) must not
    /// hold it up: macOS would switch the keyboard tap off, and keys would
    /// come out of order.
    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let el = element as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.08)
        return el
    }

    /// Where the text cursor of the focused app is, in screen coordinates
    /// (bottom-left origin), read through Accessibility.
    static func caretRect() -> NSRect? {
        guard let el = focusedElement() else { return nil }
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        // Accessibility measures from the top of the main screen.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
}
