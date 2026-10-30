#if SHELF_DRAG_STANDALONE_CHECKS
import AppKit
import Defaults
import SwiftUI
@testable import Browww

@main
struct ShelfDragCheck {
    @MainActor
    static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.hasPrefix("/tmp/"), NSHomeDirectory() == home,
              FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path.hasPrefix(home + "/") else {
            preconditionFailure("Run with CFFIXED_USER_HOME set to a fresh /tmp directory; never use the user's Shelf")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        UserDefaults.standard.setVolatileDomain([
            "hudReplacement": false, "showMirror": false, "showBatteryIndicator": false,
            "firstLaunch": false, "hideNotchOption": "never",
            "mediaController": MediaControllerType.appleMusic.rawValue
        ], forName: UserDefaults.argumentDomain)
        app.finishLaunching()
        let enhanced = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enhanced) {
            _ = app.perform(enhanced, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        }
        Defaults[.boringShelf] = true
        let coordinator = BoringViewCoordinator.shared
        coordinator.currentView = .usage
        let shelf = ShelfStateViewModel.shared
        precondition(shelf.items.isEmpty, "The regression must start with isolated empty storage")
        let vm = BoringViewModel()
        let otherDisplay = BoringViewModel()
        let host = NSHostingView(rootView: ContentView().environmentObject(vm)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .frame(width: windowSize.width, height: windowSize.height))
        host.frame = NSRect(origin: .zero, size: windowSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.close()
            vm.destroy()
            otherDisplay.destroy()
            MusicManager.shared.destroy()
        }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()

        vm.expandedDragTargeting = true
        try await until("Entering the compact trigger must open a transient Shelf preview") {
            vm.notchState == .open && vm.displayedView == .shelf
        }
        try await until("The real Shelf drop surface must be mounted") {
            host.layoutSubtreeIfNeeded()
            return node(in: host, label: "Shelf storage") != nil
        }
        precondition(coordinator.currentView == .usage && Defaults[.lastSelectedTab] == .usage, "Hover must not select or persist Shelf")
        precondition(otherDisplay.displayedView == .usage, "A drag preview must stay on its own display")
        vm.updateUsageContentHeight(120)
        precondition(vm.notchSize == openNotchSize, "Late Usage measurements must not resize a Shelf preview")
        try snapshot(host, to: URL(fileURLWithPath: home).appendingPathComponent("shelf-drag-preview.png"))
        vm.clearDropTargeting()
        try await until("Cancelling a drag must dismiss the preview") { vm.notchState == .closed }
        precondition(coordinator.currentView == .usage && Defaults[.lastSelectedTab] == .usage && shelf.items.isEmpty,
                     "Cancellation must retain both the selected tab and the empty Shelf")

        vm.expandedDragTargeting = true
        try await until("A subsequent drag must still preview Shelf") { vm.notchState == .open && vm.displayedView == .shelf }
        let provider = NSItemProvider(object: URL(string: "https://example.com/shelf-drag-check")! as NSURL)
        vm.dropEvent = true
        shelf.load([provider])
        vm.clearDropTargeting()
        try await until("A successful provider load must finish") { !shelf.isLoading }
        precondition(shelf.items.count == 1 && coordinator.currentView == .shelf && Defaults[.lastSelectedTab] == .shelf,
                     "Only a newly inserted item may select and persist Shelf")
        host.layoutSubtreeIfNeeded()
        try snapshot(host, to: URL(fileURLWithPath: home).appendingPathComponent("shelf-drag-added.png"))
        try await Task.sleep(for: .milliseconds(600))
        vm.close()

        coordinator.currentView = .usage
        shelf.load([NSItemProvider()])
        try await until("An unsupported provider must finish without adding an item") { !shelf.isLoading }
        precondition(shelf.items.count == 1 && coordinator.currentView == .usage && Defaults[.lastSelectedTab] == .usage,
                     "An empty provider result must not select Shelf, even when it already contains items")
        shelf.load([provider])
        try await until("A duplicate drop must finish") { !shelf.isLoading }
        precondition(shelf.items.count == 1 && coordinator.currentView == .usage && Defaults[.lastSelectedTab] == .usage,
                     "A deduplicated drop must not select Shelf")
        shelf.load([])
        precondition(coordinator.currentView == .usage && !shelf.isLoading, "No providers must leave the selected tab alone")

        vm.expandedDragTargeting = true
        try await until("A populated Shelf may still be previewed") { vm.notchState == .open && vm.displayedView == .shelf }
        vm.clearDropTargeting()
        try await until("Cancellation with existing items must dismiss the preview") { vm.notchState == .closed }
        precondition(shelf.items.count == 1 && coordinator.currentView == .usage && Defaults[.lastSelectedTab] == .usage,
                     "Existing Shelf content does not turn a cancelled drag into a successful drop")
        precondition(!window.isVisible && !app.isActive, "Native checks must never activate a window")
        print("Shelf drag: native hover/cancel retain Usage and its saved selection; actual insertion selects Shelf; empty/unsupported/duplicate drops do not; populated Shelf cancellation and per-display sizing passed; windowVisible=false; home=\(home)")
    }

    @MainActor
    static func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(condition(), message)
    }

    @MainActor
    static func snapshot(_ host: NSView, to url: URL) throws {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("Native rendering failed") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { preconditionFailure("Native PNG encoding failed") }
        try png.write(to: url)
    }

    @MainActor
    static func node(in element: NSObject, label: String) -> NSObject? {
        func value(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
        }
        if ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains(where: { value($0) as? String == label }) {
            return element
        }
        for child in value("accessibilityChildren") as? [NSObject] ?? [] {
            if let match = node(in: child, label: label) { return match }
        }
        return nil
    }
}
#endif
