#if NOTCH_TAB_MEMORY_STANDALONE_CHECKS
import AppKit
import Defaults
@testable import Browww

@main
struct NotchTabMemoryCheck {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        UserDefaults.standard.setVolatileDomain([
            "hudReplacement": false, "firstLaunch": false,
            "showMirror": false, "hideNotchOption": "never"
        ], forName: UserDefaults.argumentDomain)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let mode = arguments.first {
            switch mode {
            case "seed":
                UserDefaults.standard.set(arguments[1], forKey: "lastSelectedTab")
                Defaults[.boringShelf] = arguments[2] == "true"
            case "select":
                Defaults[.boringShelf] = true
                let coordinator = BoringViewCoordinator.shared
                let expected = NotchViews(rawValue: arguments[1])!
                coordinator.currentView = expected
                let vm = BoringViewModel()
                vm.close()
                vm.close()
                coordinator.alwaysShowTabs = false
                coordinator.alwaysShowTabs = true
                precondition(coordinator.currentView == expected, "Closing or hiding tabs must preserve selection")
            case "read":
                let coordinator = BoringViewCoordinator.shared
                precondition(coordinator.currentView.rawValue == arguments[1], "A fresh process must restore the last available tab")
                precondition(UserDefaults.standard.string(forKey: "lastSelectedTab") == arguments[1], "Unavailable or invalid saved tabs must be normalized")
            case "disable":
                Defaults[.boringShelf] = true
                let coordinator = BoringViewCoordinator.shared
                let selected = NotchViews(rawValue: arguments[1])!
                coordinator.currentView = selected
                Defaults[.boringShelf] = false
                try await Task.sleep(for: .milliseconds(100))
                let expected: NotchViews = selected == .shelf ? .home : selected
                precondition(coordinator.currentView == expected, "Disabling Shelf must replace only a Shelf selection")
                precondition(Defaults[.lastSelectedTab] == expected, "Shelf availability changes must persist the valid selection")
            default:
                preconditionFailure("Unknown check operation")
            }
            UserDefaults.standard.synchronize()
            return
        }

        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        precondition(domain != "local.browww", "Use the standalone check executable, not the installed app")
        let previous = UserDefaults.standard.persistentDomain(forName: domain)
        defer {
            if let previous {
                UserDefaults.standard.setPersistentDomain(previous, forName: domain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
            UserDefaults.standard.synchronize()
        }
        let operations = [
            ["select", "usage"], ["read", "usage"],
            ["select", "shelf"], ["read", "shelf"],
            ["select", "home"], ["read", "home"],
            ["select", "timer"], ["read", "timer"],
            ["seed", "unknown-tab", "true"], ["read", "home"],
            ["seed", "shelf", "false"], ["read", "home"],
            ["disable", "shelf"], ["read", "home"],
            ["disable", "usage"], ["read", "usage"]
        ]
        for operation in operations {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            child.arguments = operation
            try child.run()
            child.waitUntilExit()
            precondition(child.terminationStatus == 0, "Tab memory scenario failed: \(operation)")
        }
        print("Tab memory: close/visibility preserve selection; fresh processes restore Home/Shelf/Usage/Timer; invalid and disabled Shelf selections normalize; no visible UI")
    }
}
#endif
