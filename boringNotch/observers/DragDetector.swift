//
//  DragDetector.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-20.
//

import Cocoa
import UniformTypeIdentifiers

final class DragDetector {

    // MARK: - Callbacks

    typealias VoidCallback = () -> Void
    typealias PositionCallback = (_ globalPoint: CGPoint) -> Void

    var onDragEntersNotchRegion: VoidCallback?
    var onDragExitsNotchRegion: VoidCallback?
    var onDragMove: PositionCallback?
    var onDragEnded: VoidCallback?


    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var releaseTimer: Timer?

    private var pasteboardChangeCount: Int = -1
    private var isDragging: Bool = false
    private var isContentDragging: Bool = false
    private var hasEnteredNotchRegion: Bool = false

    private let notchRegion: CGRect
    private let dragPasteboard: NSPasteboard

    init(notchRegion: CGRect, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) {
        self.notchRegion = notchRegion
        self.dragPasteboard = pasteboard
    }

    static func activationRegion(in screenFrame: CGRect, notchSize: CGSize) -> CGRect {
        // A small margin around the closed notch, not the open panel or its shadow.
        CGRect(
            x: screenFrame.midX - notchSize.width / 2 - 12,
            y: screenFrame.maxY - notchSize.height - 12,
            width: notchSize.width + 24,
            height: notchSize.height + 12
        )
    }

    // MARK: - Private Helpers
    
    /// Checks if the drag pasteboard contains valid content types that can be dropped on the shelf
    private func hasValidDragContent() -> Bool {
        let validTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType(UTType.url.identifier),
            .string
        ]
        return dragPasteboard.types?.contains(where: validTypes.contains) ?? false
    }

    func startMonitoring() {
        stopMonitoring()
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: beginDrag()
        case .leftMouseDragged: updateDrag(at: NSEvent.mouseLocation)
        case .leftMouseUp: endDrag()
        default: break
        }
    }

    func beginDrag() {
        endDrag()
        pasteboardChangeCount = dragPasteboard.changeCount
        isDragging = true
        isContentDragging = false
        hasEnteredNotchRegion = false
    }

    func updateDrag(at position: CGPoint) {
        guard isDragging else { return }

        if dragPasteboard.changeCount != pasteboardChangeCount && !isContentDragging && hasValidDragContent() {
            isContentDragging = true
            // Native drag tracking can consume mouse-up; check the real button state until release.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.endDragIfReleased(pressedMouseButtons: NSEvent.pressedMouseButtons)
            }
            releaseTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        guard isContentDragging else { return }
        onDragMove?(position)

        let containsMouse = notchRegion.contains(position)
        if containsMouse && !hasEnteredNotchRegion {
            hasEnteredNotchRegion = true
            onDragEntersNotchRegion?()
        } else if !containsMouse && hasEnteredNotchRegion {
            hasEnteredNotchRegion = false
            onDragExitsNotchRegion?()
        }
    }

    func endDragIfReleased(pressedMouseButtons: Int) {
        if pressedMouseButtons & 1 == 0 {
            endDrag()
        }
    }

    func endDrag() {
        let wasContentDragging = isContentDragging
        let wasInNotchRegion = hasEnteredNotchRegion
        releaseTimer?.invalidate()
        releaseTimer = nil
        isDragging = false
        isContentDragging = false
        hasEnteredNotchRegion = false
        pasteboardChangeCount = -1
        if wasInNotchRegion { onDragExitsNotchRegion?() }
        if wasContentDragging { onDragEnded?() }
    }

    func stopMonitoring() {
        [globalMonitor, localMonitor].forEach { monitor in
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalMonitor = nil
        localMonitor = nil
        endDrag()
    }

    deinit {
        stopMonitoring()
    }
}
