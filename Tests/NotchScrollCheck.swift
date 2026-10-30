import AppKit

#if NOTCH_STANDALONE_CHECKS
@main
struct NotchScrollCheck {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 210),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 210))
        window.contentView = content

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 600, height: 120))
        scroll.hasVerticalScroller = true
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 800))
        content.addSubview(scroll)
        content.layoutSubtreeIfNeeded()

        let header = content.convert(NSPoint(x: 30, y: 180), to: nil)
        let body = content.convert(NSPoint(x: 40, y: 50), to: nil)
        let outside = content.convert(NSPoint(x: 700, y: 180), to: nil)
        assert(shouldHandleNotchScroll(at: header, in: content), "Header scroll gestures must still close the notch")
        assert(!shouldHandleNotchScroll(at: body, in: content), "Content scrolling must not close the notch")
        assert(!shouldHandleNotchScroll(at: outside, in: content), "Other regions of the window must not trigger a view's gesture")

        window.close()
        print("Notch scroll routing: content scrolling is isolated; header gestures remain available")
    }
}
#endif
