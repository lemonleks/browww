import AppKit
import Combine
import Foundation

@MainActor
final class OmpUsageStore: ObservableObject {
    typealias Probe = @Sendable (_ force: Bool, _ binaryPath: String) async throws -> OmpUsageSnapshot

    static let staleInterval: TimeInterval = 300
    nonisolated static let panelRefreshInterval: TimeInterval = 60
    static let shared = OmpUsageStore()

    @Published private(set) var snapshot: OmpUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastAttemptAt: Date?
    @Published var binaryPath: String {
        didSet { defaults.set(binaryPath, forKey: Self.binaryPathKey) }
    }

    private static let binaryPathKey = "OmpUsage.binaryPath"
    private let defaults: UserDefaults
    private let probe: Probe
    private let refreshInterval: TimeInterval
    private var refreshTask: Task<Void, Never>?
    private var refreshIsForced = false
    private var monitorTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        probe: Probe? = nil,
        refreshInterval: TimeInterval = OmpUsageStore.panelRefreshInterval
    ) {
        self.defaults = defaults
        self.probe = probe ?? { force, binaryPath in
            try await Self.liveProbe(force: force, binaryPath: binaryPath)
        }
        self.refreshInterval = refreshInterval
        self.binaryPath = defaults.string(forKey: Self.binaryPathKey) ?? ""
    }

    func refresh(force: Bool = false) async {
        if let refreshTask {
            let needsForcedFollowUp = force && !refreshIsForced
            await refreshTask.value
            if needsForcedFollowUp { await refresh(force: true) }
            return
        }
        guard force || !isWithinPanelThrottle else { return }

        lastAttemptAt = Date()
        isRefreshing = true
        let probe = probe
        let binaryPath = binaryPath
        let task = Task { [weak self, probe, binaryPath] in
            do {
                let snapshot = try await probe(force, binaryPath)
                guard !Task.isCancelled else {
                    self?.finishCancellation()
                    return
                }
                self?.finish(snapshot: snapshot)
            } catch is CancellationError {
                self?.finishCancellation()
            } catch {
                self?.finish(error: error)
            }
        }
        refreshTask = task
        refreshIsForced = force
        await task.value
    }

    func startMonitoring() {
        guard monitorTimer == nil else { return }
        monitorTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private var isWithinPanelThrottle: Bool {
        guard let lastAttemptAt else { return false }
        return Date().timeIntervalSince(lastAttemptAt) < refreshInterval
    }

    private func finish(snapshot: OmpUsageSnapshot) {
        self.snapshot = snapshot
        lastError = nil
        isRefreshing = false
        refreshTask = nil
        refreshIsForced = false
    }

    private func finishCancellation() {
        isRefreshing = false
        refreshTask = nil
        refreshIsForced = false
    }

    private func finish(error: Error) {
        if let message = Self.safeMessage(for: error) {
            lastError = message
        }
        isRefreshing = false
        refreshTask = nil
        refreshIsForced = false
    }

    private static func safeMessage(for error: Error) -> String? {
        if error is CancellationError { return nil }
        if let error = error as? OmpUsageProcessError {
            return error.errorDescription
        }
        if let error = error as? OmpUsageError {
            return error.errorDescription
        }
        let error = error as NSError
        if error.domain == "Browww.OmpUsage" {
            return error.localizedDescription
        }
        // XPC and injected probes can carry account details in raw errors.
        return "Could not refresh Oh My Pi usage. Run `omp usage` in Terminal, then try again."
    }

    private nonisolated static func liveProbe(force: Bool, binaryPath: String) async throws -> OmpUsageSnapshot {
        #if OMP_STANDALONE_CHECKS
        let output = try await OmpUsageProcess.fetch(binaryPath: binaryPath, force: force)
        #else
        let output = try await XPCHelperClient.shared.fetchOmpUsage(binaryPath: binaryPath, force: force)
        #endif
        return try OmpUsageProbe.parse(output)
    }
}
