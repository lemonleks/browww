import AppKit

#if NOTCH_DRAG_STANDALONE_CHECKS
@main
struct NotchDragCheck {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let screen = CGRect(x: 1440, y: -200, width: 1440, height: 900)
        let notchSize = CGSize(width: 185, height: 32)
        let inside = CGPoint(x: screen.midX, y: screen.maxY - notchSize.height / 2)
        let outside = CGPoint(x: screen.midX + 250, y: screen.maxY - 100)
        let detector = DragDetector(
            notchRegion: DragDetector.activationRegion(in: screen, notchSize: notchSize),
            pasteboard: pasteboard
        )
        var isDropAreaOpen = false
        var completionCount = 0
        detector.onDragEntersNotchRegion = { isDropAreaOpen = true }
        detector.onDragExitsNotchRegion = { isDropAreaOpen = false }
        detector.onDragEnded = { completionCount += 1 }

        detector.beginDrag()
        pasteboard.clearContents()
        pasteboard.setString("https://example.com", forType: .string)
        detector.updateDrag(at: outside)
        assert(!isDropAreaOpen, "The old open-panel-sized region must not trigger Shelf away from the closed notch")
        detector.updateDrag(at: inside)
        assert(isDropAreaOpen, "A supported content drag must expose the drop area")
        detector.endDrag()
        assert(!isDropAreaOpen, "Ending a drag must dismiss its active drop area even without a final drag-exit event")
        assert(completionCount == 1, "A content drag must complete once")
        detector.endDrag()
        assert(completionCount == 1, "Mouse-up and the release fallback must not complete the same drag twice")

        detector.beginDrag()
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/next", forType: .string)
        detector.updateDrag(at: inside)
        detector.endDragIfReleased(pressedMouseButtons: 1)
        assert(isDropAreaOpen, "An active drag must not be dismissed while the left button is held")
        detector.updateDrag(at: outside)
        assert(!isDropAreaOpen, "Moving to another drop destination must dismiss the notch target")
        detector.endDragIfReleased(pressedMouseButtons: 0)
        assert(completionCount == 2, "Release outside must complete even if no mouse-up event arrives")
        detector.updateDrag(at: inside)
        assert(!isDropAreaOpen, "An ended drag must not reopen from a late move event")

        detector.beginDrag()
        detector.updateDrag(at: inside)
        detector.endDrag()
        assert(!isDropAreaOpen && completionCount == 2, "A mouse drag without new transferable content is not a Shelf drag")

        detector.beginDrag()
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/cancel", forType: .string)
        detector.updateDrag(at: inside)
        detector.stopMonitoring()
        assert(!isDropAreaOpen && completionCount == 3, "Stopping detection must cancel its outstanding target")
        print("Notch drag lifecycle: compact closed-notch region on an offset display; release inside/outside, missing mouse-up, cancellation and late events passed")
    }
}
#endif
