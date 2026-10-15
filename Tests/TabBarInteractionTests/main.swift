import AppKit

@MainActor enum Theme { static var accent: NSColor { .controlAccentColor } }
enum L10n { static func t(_ key: String) -> String { key } }

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    let bar = TabBarView(frame: NSRect(x: 80, y: 360, width: 800, height: 40))
    bar.itemHeight = 28
    window.contentView!.addSubview(bar)
    bar.update(titles: ["First workspace", "Second workspace"], active: 0)
    window.contentView!.layoutSubtreeIfNeeded()

    @MainActor func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    let closeButtons = descendants(bar).compactMap { $0 as? NSButton }.filter { $0.action == Selector(("closeTab")) }
    precondition(closeButtons.count == 2)
    var closed: [Int] = []
    var selected: [Int] = []
    bar.onClose = { closed.append($0) }
    bar.onSelect = { selected.append($0) }
    for (index, button) in closeButtons.enumerated() {
        button.isHidden = false // Equivalent to hovering the tab.
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: bar.superview)
        let target = bar.hitTest(point)
        precondition(target === button, "Close hit resolved to \(String(describing: target)), expected NSButton for tab \(index)")
        (target as! NSButton).performClick(nil)
    }
    precondition(closed == [0, 1] && selected.isEmpty, "Close must not select a workspace")
    // The row padding still selects a tab, including a nonzero parent-space origin.
    for index in 0..<2 {
        let frame = bar.uiTestItemFrame(index)!
        let point = NSPoint(x: frame.midX, y: 1)
        precondition(bar.uiTestHitsItem(index, at: point))
        _ = bar.uiTestClickResolved(at: point, in: window)
    }
    precondition(selected == [0, 1] && closed == [0, 1], "Row selection must not close tabs")
    print("PASS: active/inactive workspace close buttons and full-row selection")
}
