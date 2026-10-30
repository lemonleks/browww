import AppKit

#if NOTCH_TAB_SCROLL_STANDALONE_CHECKS
@main
struct NotchTabScrollCheck {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var state = TabScrollGestureState()
        func input(
            _ x: CGFloat, _ y: CGFloat = 0, phase: NSEvent.Phase = .changed,
            momentum: NSEvent.Phase = [], inside: Bool = true, natural: Bool = true
        ) -> (consume: Bool, direction: PanDirection?) {
            state.handle(delta: CGSize(width: x, height: y), phase: phase, momentumPhase: momentum,
                         inside: inside, naturalScrolling: natural, threshold: 20)
        }

        let start = input(-12, phase: .began)
        assert(start.consume && start.direction == nil, "A horizontal gesture must not scroll its content while accumulating")
        let advance = input(-12)
        assert(advance.consume && advance.direction == .left, "An intentional left swipe must advance a tab")
        for _ in 0..<5 {
            let continuation = input(-80)
            assert(continuation.consume && continuation.direction == nil, "A held gesture must switch only once")
        }
        assert(input(0, phase: .ended).consume)
        for momentum in [NSEvent.Phase.began, .changed, .ended] {
            let inertia = input(-120, phase: [], momentum: momentum)
            assert(inertia.consume && inertia.direction == nil, "Horizontal momentum must not switch or scroll the new tab")
        }
        let back = input(24, phase: .began)
        assert(back.direction == .right, "A new right swipe must return to the previous tab")
        _ = input(0, phase: .ended)

        let reversedPreference = input(24, phase: .began, natural: false)
        assert(reversedPreference.direction == .left, "Tab direction must follow fingers with natural scrolling disabled too")
        _ = input(0, phase: .ended)

        let vertical = input(1, 60, phase: .began)
        assert(!vertical.consume && vertical.direction == nil, "Vertical content scrolling must pass through")
        let drift = input(-100)
        assert(!drift.consume && drift.direction == nil, "A vertical gesture must not turn into tab navigation from late drift")
        _ = input(0, phase: .ended)

        let outside = input(-30, phase: .began, inside: false)
        assert(!outside.consume && outside.direction == nil, "A gesture starting outside must pass through")
        let entering = input(-30)
        assert(!entering.consume && entering.direction == nil, "Entering the panel mid-gesture must not capture it")
        _ = input(0, phase: .ended)

        _ = input(-24, phase: .began)
        let leaving = input(-60, inside: false)
        assert(!leaving.consume && leaving.direction == nil, "Events outside the panel must not be swallowed")
        let returning = input(-60)
        assert(returning.consume && returning.direction == nil, "Re-entering must not switch twice in the same gesture")
        _ = input(0, phase: .cancelled)
        let cancelledMomentum = input(-80, phase: [], momentum: .began)
        assert(!cancelledMomentum.consume && cancelledMomentum.direction == nil, "Cancellation must discard gesture ownership")

        state.reset()
        let missingBegin = input(-40)
        assert(!missingBegin.consume && missingBegin.direction == nil, "A stray change event must not navigate")
        let tooShort = input(-6, phase: .began)
        assert(tooShort.direction == nil, "Short horizontal motion must not navigate")
        _ = input(0, phase: .ended)
        let shortInertia = input(-100, phase: [], momentum: .began)
        assert(shortInertia.consume && shortInertia.direction == nil, "Inertia must not complete a short gesture's threshold")

        state.reset()
        let diagonal = input(12, 12, phase: .began)
        assert(!diagonal.consume && diagonal.direction == nil, "Ambiguous diagonal motion must not navigate")
        state.reset()
        assert(input(-40).direction == nil, "Disabling or dismantling the monitor must discard an active sequence")
        print("Notch tab scroll: direction, one-shot switching, axis lock, momentum, bounds and cancellation passed")
    }
}
#endif
