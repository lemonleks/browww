import Foundation
import Combine
import UserNotifications

struct SessionTimerState: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case focus, rest
    }

    enum Phase: Codable, Equatable, Sendable {
        case idle
        case running(deadline: Date)
        case paused(remaining: TimeInterval)
    }

    private(set) var mode: Mode
    private(set) var focusMinutes: Int
    private(set) var breakMinutes: Int
    private(set) var phase: Phase

    init() {
        mode = .focus
        focusMinutes = 25
        breakMinutes = 5
        phase = .idle
    }

    private enum CodingKeys: String, CodingKey {
        case mode, focusMinutes, breakMinutes, phase
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(Mode.self, forKey: .mode)
        focusMinutes = try values.decode(Int.self, forKey: .focusMinutes)
        breakMinutes = try values.decode(Int.self, forKey: .breakMinutes)
        phase = try values.decode(Phase.self, forKey: .phase)

        var valid = (1...180).contains(focusMinutes) && (1...180).contains(breakMinutes)
        switch phase {
        case .idle:
            break
        case .running(let deadline):
            valid = valid && deadline.timeIntervalSinceReferenceDate.isFinite
        case .paused(let remaining):
            valid = valid && remaining.isFinite && remaining > 0 && remaining <= configuredSeconds
        }
        guard valid else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid session timer state"
            ))
        }
    }

    func minutes(for mode: Mode) -> Int {
        mode == .focus ? focusMinutes : breakMinutes
    }

    private var configuredSeconds: TimeInterval {
        TimeInterval(minutes(for: mode)) * 60
    }

    func remaining(at now: Date) -> TimeInterval {
        switch phase {
        case .idle:
            return configuredSeconds
        case .paused(let remaining):
            return remaining
        case .running(let deadline):
            return min(configuredSeconds, max(0, deadline.timeIntervalSince(now)))
        }
    }

    func isRunning(at now: Date) -> Bool {
        if case .running = phase {
            return remaining(at: now) > 0
        }
        return false
    }

    func isFinished(at now: Date) -> Bool {
        if case .running(let deadline) = phase {
            return deadline <= now
        }
        return false
    }

    mutating func selectMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        reset()
    }

    mutating func setMinutes(_ minutes: Int, for mode: Mode) {
        guard (1...180).contains(minutes), minutes != self.minutes(for: mode) else { return }
        switch mode {
        case .focus: focusMinutes = minutes
        case .rest: breakMinutes = minutes
        }
        if mode == self.mode { reset() }
    }

    mutating func start(at now: Date) {
        guard now.timeIntervalSinceReferenceDate.isFinite, !isRunning(at: now) else { return }
        let seconds = remaining(at: now)
        phase = .running(deadline: now.addingTimeInterval(seconds > 0 ? seconds : configuredSeconds))
    }

    mutating func pause(at now: Date) {
        guard case .running = phase else { return }
        let seconds = remaining(at: now)
        guard seconds > 0 else { return }
        phase = .paused(remaining: seconds)
    }

    mutating func reset() {
        phase = .idle
    }
}

@MainActor
final class SessionTimerStore: ObservableObject {
    /// Reconciles the finish notification with a state; nil when no authorization check was needed.
    typealias Notifier = @MainActor (SessionTimerState) async -> Bool?

    static let shared = SessionTimerStore()

    @Published private(set) var state: SessionTimerState
    @Published private(set) var notificationsDenied = false

    private static let stateKey = "SessionTimer.state"
    private static let notificationID = "SessionTimer.finished"
    private let defaults: UserDefaults
    private let notifier: Notifier
    private var notificationSync: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, notifier: @escaping Notifier = SessionTimerStore.liveNotifier) {
        self.defaults = defaults
        self.notifier = notifier
        if let data = defaults.data(forKey: Self.stateKey),
           let restored = try? JSONDecoder().decode(SessionTimerState.self, from: data) {
            state = restored
        } else {
            state = SessionTimerState()
        }
    }

    func selectMode(_ mode: SessionTimerState.Mode) {
        update { $0.selectMode(mode) }
    }

    func setMinutes(_ minutes: Int, for mode: SessionTimerState.Mode) {
        update { $0.setMinutes(minutes, for: mode) }
    }

    func start(at now: Date = Date()) {
        update { $0.start(at: now) }
    }

    func pause(at now: Date = Date()) {
        update { $0.pause(at: now) }
    }

    func reset() {
        update { $0.reset() }
    }

    private func update(_ change: (inout SessionTimerState) -> Void) {
        var next = state
        change(&next)
        guard next != state, let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.stateKey)
        state = next
        // Serialized so a pause or reset can never be overtaken by an older pending add.
        let previous = notificationSync
        notificationSync = Task { [weak self] in
            await previous?.value
            guard let self, let allowed = await self.notifier(self.state) else { return }
            self.notificationsDenied = !allowed
        }
    }

    static func liveNotifier(_ state: SessionTimerState) async -> Bool? {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        guard case .running(let deadline) = state.phase, deadline > Date() else { return nil }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        guard deadline > Date() else { return true }
        let minutes = state.minutes(for: state.mode)
        let content = UNMutableNotificationContent()
        content.title = state.mode == .focus ? "Focus finished" : "Break finished"
        content.body = state.mode == .focus
            ? "Your \(minutes)-minute focus session is complete."
            : "Your \(minutes)-minute break is complete."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger))
        return true
    }
}
