//
//  PanGesture.swift
//  boringNotch
//
//  Created by Richard Kunkli on 21/08/2024.
//

import AppKit
import SwiftUI

enum PanDirection {
    case left, right, up, down

    var isHorizontal: Bool { self == .left || self == .right }
    var sign: CGFloat { (self == .right || self == .down) ? 1 : -1 }

    func signed(from translation: CGSize) -> CGFloat { (isHorizontal ? translation.width : translation.height) * sign }
    func signed(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat { (isHorizontal ? deltaX : deltaY) * sign }
}

@MainActor
func shouldHandleNotchScroll(at locationInWindow: NSPoint, in view: NSView) -> Bool {
    guard let contentView = view.window?.contentView,
          view.bounds.contains(view.convert(locationInWindow, from: nil)) else { return false }

    let point = contentView.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
    var target = contentView.hitTest(point)
    while let candidate = target {
        if candidate is NSScrollView { return false }
        target = candidate.superview
    }
    return true
}

extension View {
    func panGesture(direction: PanDirection, threshold: CGFloat = 4, action: @escaping (CGFloat, NSEvent.Phase) -> Void) -> some View {
        self
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let s = direction.signed(from: value.translation)
                        guard s > 0, s.magnitude >= threshold else { return }
                        action(s.magnitude, .changed)
                    }
                    .onEnded { _ in action(0, .ended) }
            )
            .background(ScrollMonitor(direction: direction, threshold: threshold, action: action))
    }

    func tabScrollGesture(enabled: Bool, threshold: CGFloat, action: @escaping (PanDirection) -> Void) -> some View {
        background(TabScrollMonitor(enabled: enabled, threshold: threshold, action: action))
    }
}

private struct ScrollMonitor: NSViewRepresentable {
    let direction: PanDirection
    let threshold: CGFloat
    let action: (CGFloat, NSEvent.Phase) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor(on: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.removeMonitor() }

    func makeCoordinator() -> Coordinator { 
        Coordinator(direction: direction, threshold: threshold, action: action) 
    }

    @MainActor final class Coordinator: NSObject {
        private let direction: PanDirection
        private let threshold: CGFloat
        private let action: (CGFloat, NSEvent.Phase) -> Void
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var active = false
            private var endTask: Task<Void, Never>?
        private let noiseThreshold: CGFloat = 0.2

        init(direction: PanDirection, threshold: CGFloat, action: @escaping (CGFloat, NSEvent.Phase) -> Void) {
            self.direction = direction
            self.threshold = threshold
            self.action = action
        }

        private func scheduleEndTimeout() {
            // Cancel any existing scheduled end and schedule a new one.
            endTask?.cancel()
            endTask = Task { @MainActor in
                // If no new scroll event arrives within this window, consider the gesture ended.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
            }
        }

        func installMonitor(on view: NSView) {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                guard let self, let view, event.window === view.window,
                      shouldHandleNotchScroll(at: event.locationInWindow, in: view) else { return event }
                self.handleScroll(event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            accumulated = 0
            active = false
            endTask?.cancel()
            endTask = nil
        }

        private func handleScroll(_ event: NSEvent) {
            if event.phase == .ended || event.momentumPhase == .ended {
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
                return
            }

            // Only consider scroll events that are primarily along the configured axis.
            let absDX = abs(event.scrollingDeltaX)
            let absDY = abs(event.scrollingDeltaY)
            // Require the movement along the gesture axis to be at least 1.5x the orthogonal axis.
            let axisDominanceFactor: CGFloat = 1.5
            let isAxisDominant: Bool = direction.isHorizontal ? (absDX >= axisDominanceFactor * absDY) : (absDY >= axisDominanceFactor * absDX)
            guard isAxisDominant else { return }

            // Scale non-precise (mouse wheel) scrolling deltas so they feel similar to
            // trackpad gestures.
            let raw = direction.signed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let s = raw * scale
            guard s.magnitude > noiseThreshold else { return }
            accumulated = s > 0 ? accumulated + s : 0

            if !active && accumulated >= threshold {
                active = true
                action(accumulated.magnitude, .began)
            } else if active {
                action(accumulated.magnitude, .changed)
            }
            // Schedule a timeout to end the gesture if no further scroll events arrive.
            scheduleEndTimeout()
        }
    }
}

struct TabScrollGestureState {
    private var accepted = false
    private var movement = CGSize.zero
    private var axis: Axis?
    private var switched = false
    private var consumesMomentum = false

    mutating func reset() { self = Self() }

    mutating func handle(
        delta: CGSize, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase,
        inside: Bool, naturalScrolling: Bool, threshold: CGFloat
    ) -> (consume: Bool, direction: PanDirection?) {
        if !momentumPhase.isEmpty {
            let consume = inside && consumesMomentum
            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) { reset() }
            return (consume, nil)
        }
        if phase.contains(.began) {
            reset()
            accepted = inside
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            let horizontal = accepted && axis == .horizontal
            reset()
            consumesMomentum = horizontal && !phase.contains(.cancelled)
            return (inside && horizontal, nil)
        }
        guard accepted, inside, !phase.isEmpty else { return (false, nil) }
        if axis == .vertical { return (false, nil) }
        if switched { return (true, nil) }

        movement.width += delta.width
        movement.height += delta.height
        let x = abs(movement.width)
        let y = abs(movement.height)
        if axis == nil {
            if x >= 4 && x >= y * 1.5 { axis = .horizontal }
            else if y >= 4 && y >= x * 1.5 { axis = .vertical }
        }
        guard axis == .horizontal else { return (false, nil) }
        guard x >= max(4, threshold) else { return (true, nil) }

        switched = true
        // Follow finger direction, not the user's reversed scrolling preference.
        let fingerMovement = movement.width * (naturalScrolling ? 1 : -1)
        return (true, fingerMovement < 0 ? .left : .right)
    }
}

private struct TabScrollMonitor: NSViewRepresentable {
    let enabled: Bool
    let threshold: CGFloat
    let action: (PanDirection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(enabled: enabled, threshold: threshold, action: action) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.configure(enabled: enabled, threshold: threshold, action: action)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.removeMonitor() }

    @MainActor final class Coordinator {
        private var enabled: Bool
        private var threshold: CGFloat
        private var action: (PanDirection) -> Void
        private var monitor: Any?
        private var state = TabScrollGestureState()

        init(enabled: Bool, threshold: CGFloat, action: @escaping (PanDirection) -> Void) {
            self.enabled = enabled
            self.threshold = threshold
            self.action = action
        }

        func configure(enabled: Bool, threshold: CGFloat, action: @escaping (PanDirection) -> Void) {
            self.enabled = enabled
            self.threshold = threshold
            self.action = action
            if !enabled { state.reset() }
        }

        func install(on view: NSView) {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                guard let self, let view, self.enabled, event.hasPreciseScrollingDeltas else { return event }
                let inside = view.window != nil && event.window === view.window
                    && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
                let result = self.state.handle(
                    delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                    phase: event.phase, momentumPhase: event.momentumPhase,
                    inside: inside, naturalScrolling: event.isDirectionInvertedFromDevice,
                    threshold: self.threshold
                )
                if let direction = result.direction { self.action(direction) }
                return result.consume ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            state.reset()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
