#if OMP_USAGE_SCROLL_STANDALONE_CHECKS
import AppKit
import SwiftUI
@testable import Browww

@main
struct OmpUsageScrollCheck {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        UserDefaults.standard.setVolatileDomain([
            "hudReplacement": false, "showMirror": false,
            "showBatteryIndicator": false, "firstLaunch": false,
            "hideNotchOption": "never"
        ], forName: UserDefaults.argumentDomain)
        NSApp.finishLaunching()
        let enhanced = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if NSApp.responds(to: enhanced) {
            _ = NSApp.perform(enhanced, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        }

        let now = Date()
        let fetchedAt = now.addingTimeInterval(-240)
        func quota(_ id: String, _ account: String, _ title: String, _ used: Double, _ reset: TimeInterval?) -> OmpQuota {
            OmpQuota(
                id: id, label: "\(account) \(title)", group: account, compactTitle: title,
                percentRemaining: 100 - used, resetsAt: reset.map { now.addingTimeInterval($0) },
                fetchedAt: fetchedAt, dollarUsed: nil, dollarCap: nil
            )
        }
        let snapshot = OmpUsageSnapshot(
            quotas: [
                quota("a", "Claude", "5h", 13, 18000),
                quota("b", "Claude", "7d", 6, 518400),
                quota("c", "Claude", "Fable 7d", 2, 518400),
                quota("d", "Codex · work", "30d", 0, 2592000),
                quota("e", "Codex · personal", "7d", 34, 518400),
                quota("f", "Z.ai", "1w", 3, 172800),
                quota("g", "Z.ai", "5h", 0, nil)
            ],
            notes: [OmpUsageNote(id: "spend", group: "Claude", label: "Extra usage", value: "$1.20 spent · no cap")],
            bankedResets: [
                "Codex · work": OmpBankedResets(count: 0, expirations: []),
                "Claude": OmpBankedResets(count: 1, expirations: []),
                "Codex · personal": OmpBankedResets(count: 2, expirations: [])
            ],
            completedAt: now, fetchedAt: fetchedAt
        )
        let defaults = UserDefaults(suiteName: "browww.scroll.check.\(UUID().uuidString)")!
        let store = OmpUsageStore(defaults: defaults, probe: { _, _ in snapshot })
        await store.refresh()
        let vm = BoringViewModel()
        let root = usageView(store: store, vm: vm, height: 306)
        let host = NSHostingView(rootView: root)
        let bounds = NSRect(x: 0, y: 0, width: 578, height: 306)
        host.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        guard let codexFrame = accessibilityFrame(in: host, label: "Codex · work"),
              let claudeFrame = accessibilityFrame(in: host, label: "Claude"),
              let bankedFrame = accessibilityFrame(in: host, label: "Banked resets: 1") else {
            fatalError("Provider headers and banked resets must remain accessible")
        }
        assert(codexFrame.width > 0 && claudeFrame.width > 0 && codexFrame.midX < claudeFrame.minX, "Codex must occupy the left column and Claude the right")
        assert(bankedFrame.minX >= claudeFrame.maxX - 1 && bankedFrame.minX - claudeFrame.maxX <= 12, "Banked resets must stay beside the account name")
        assert(accessibilityFrame(in: host, label: "Banked resets: 0") == nil, "Zero banked balances must not create a caption or hide the account")
        guard let scroll = findScroll(in: host), let document = scroll.documentView else {
            fatalError("The production Usage view must have a native scroll viewport")
        }
        // Clamp the check's explicit offsets; production scrolling physics stay unchanged.
        scroll.verticalScrollElasticity = .none
        let initialHeight = document.frame.height
        let maximum = max(0, initialHeight - scroll.contentView.bounds.height)
        assert(maximum > 0, "The fixture must exercise overflow, not an unscrollable list")
        let steps = Int(ceil(maximum / 2)) + 2
        var minHeight = initialHeight
        var maxHeight = initialHeight
        for direction in [CGFloat(1), -1, 1, -1] {
            for _ in 0..<steps {
                let previous = scroll.contentView.bounds.origin.y
                let limit = max(0, document.frame.height - scroll.contentView.bounds.height)
                let requested = min(limit, max(0, previous + direction * 2))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: requested))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(8))
                host.layoutSubtreeIfNeeded()
                let actual = scroll.contentView.bounds.origin.y
                minHeight = min(minHeight, document.frame.height)
                maxHeight = max(maxHeight, document.frame.height)
                assert(abs(actual - requested) <= 0.5, "Scrolling static quotas must not correct the requested offset")
                assert((actual - previous) * direction >= -0.5, "Scrolling must not reverse without a direction change")
                assert(maxHeight - minHeight <= 0.5, "Static account rows must not change scroll extent: \(minHeight)...\(maxHeight)")
            }
            let endpoint = direction > 0 ? maximum : 0
            assert(abs(scroll.contentView.bounds.origin.y - endpoint) <= 0.5, "Every sweep must reach its content boundary")
        }
        assert(vm.sizeForOpenView(.usage).height == usageNotchSize.height, "Long lists must keep the bounded panel height")
        let shortSnapshot = OmpUsageSnapshot(
            quotas: [snapshot.quotas[0], snapshot.quotas[1], snapshot.quotas[2], snapshot.quotas[4]],
            notes: snapshot.notes,
            bankedResets: snapshot.bankedResets,
            completedAt: now, fetchedAt: fetchedAt
        )
        let shortStore = OmpUsageStore(defaults: defaults, probe: { _, _ in shortSnapshot })
        await shortStore.refresh()
        let closedSize = vm.notchSize
        host.rootView = usageView(store: shortStore, vm: vm, height: 306)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let compactHeight = vm.sizeForOpenView(.usage).height
        assert(compactHeight < usageNotchSize.height, "Short account lists must shrink the panel")
        let chrome = max(openNotchHeaderMinHeight, vm.effectiveClosedNotchHeight) + openNotchSpacing + openNotchPadding
        host.rootView = usageView(store: shortStore, vm: vm, height: compactHeight - chrome)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        guard let compactScroll = findScroll(in: host), let compactDocument = compactScroll.documentView else {
            fatalError("Compact Usage must retain its scroll viewport")
        }
        let unusedHeight = compactScroll.contentView.bounds.height - compactDocument.frame.height
        assert(abs(unusedHeight) <= 1, "Short lists must not leave an empty scroll viewport: \(unusedHeight) pt")
        let soloSnapshot = OmpUsageSnapshot(
            quotas: shortSnapshot.quotas.filter { $0.group == "Claude" },
            notes: shortSnapshot.notes, bankedResets: shortSnapshot.bankedResets,
            completedAt: now, fetchedAt: fetchedAt
        )
        let soloStore = OmpUsageStore(defaults: defaults, probe: { _, _ in soloSnapshot })
        await soloStore.refresh()
        host.rootView = usageView(store: soloStore, vm: vm, height: compactHeight - chrome)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        guard let soloFrame = accessibilityFrame(in: host, label: "Claude") else {
            fatalError("Claude must remain visible when Codex has no report")
        }
        assert(abs(soloFrame.minX - claudeFrame.minX) <= 1, "A missing Codex report must not move Claude out of the right column")
        host.rootView = usageView(store: store, vm: vm, height: compactHeight - chrome)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        assert(vm.sizeForOpenView(.usage).height == usageNotchSize.height, "New rows must grow a previously compact panel")
        assert(vm.notchState == .closed && vm.notchSize == closedSize, "Hidden layout measurement must not open the panel")
        assert(!window.isVisible, "The regression must never open a visible window")
        print("Usage scroll: fixed Codex/Claude columns, zero-reset captions omitted with accounts retained, adjacent positive banked resets and single-provider placement; four native sweeps, stable extent \(initialHeight) pt, no offset correction; compact panel \(compactHeight) pt with \(unusedHeight) pt unused; growth capped at 360 pt; windowVisible=false")
    }

    @MainActor
    static func usageView(store: OmpUsageStore, vm: BoringViewModel, height: CGFloat) -> some View {
        OmpUsageView(store: store)
            .frame(width: 578, height: height)
            .environmentObject(vm)
            .preferredColorScheme(.dark)
    }

    @MainActor
    static func accessibilityFrame(in element: NSObject, label: String) -> NSRect? {
        func value(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
        if ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains(where: { value($0) as? String == label }) {
            return (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
        }
        for child in value("accessibilityChildren") as? [NSObject] ?? [] {
            if let frame = accessibilityFrame(in: child, label: label) { return frame }
        }
        return nil
    }

    static func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = findScroll(in: child) { return scroll }
        }
        return nil
    }
}
#endif
