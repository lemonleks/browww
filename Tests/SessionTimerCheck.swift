#if SESSION_TIMER_STANDALONE_CHECKS
import Foundation


@main
struct SessionTimerCheck {
    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "restore" {
            let defaults = UserDefaults(suiteName: arguments[1])!
            let expected = try JSONDecoder().decode(
                SessionTimerState.self, from: Data(base64Encoded: arguments[2])!
            )
            let now = Date(timeIntervalSinceReferenceDate: Double(arguments[3])!)
            let store = SessionTimerStore(defaults: defaults)
            precondition(store.state == expected, "A fresh process must restore mode, durations and exact phase")
            precondition(store.state.remaining(at: now) == Double(arguments[4])!)
            switch arguments[5] {
            case "running": precondition(store.state.isRunning(at: now) && !store.state.isFinished(at: now))
            case "paused":
                guard case .paused = store.state.phase else { preconditionFailure("Paused restore must stay paused") }
                precondition(!store.state.isRunning(at: now) && !store.state.isFinished(at: now))
            case "finished": precondition(!store.state.isRunning(at: now) && store.state.isFinished(at: now))
            default: preconditionFailure("Unknown restore scenario")
            }
            return
        }

        let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var state = SessionTimerState()
        state.setMinutes(1, for: .focus)
        state.start(at: origin)
        let started = state
        state.start(at: origin.addingTimeInterval(10))
        precondition(state == started, "Start must not extend an already-running deadline")
        precondition(state.remaining(at: origin.addingTimeInterval(-100)) == 60, "Clock rollback cannot exceed the configured duration")
        precondition(state.remaining(at: origin.addingTimeInterval(0.25)) == 59.75)
        state.pause(at: origin.addingTimeInterval(0.25))
        precondition(state.phase == .paused(remaining: 59.75))
        precondition(state.remaining(at: origin.addingTimeInterval(10_000)) == 59.75, "Paused time must be immutable")
        let paused = state
        state.pause(at: origin.addingTimeInterval(20_000))
        precondition(state == paused, "Pause is idempotent")
        let resumedAt = origin.addingTimeInterval(30_000)
        state.start(at: resumedAt)
        let deadline = resumedAt.addingTimeInterval(59.75)
        precondition(state.phase == .running(deadline: deadline), "Resume must preserve fractional seconds")
        precondition(state.remaining(at: deadline.addingTimeInterval(-0.25)) == 0.25)
        precondition(state.isRunning(at: deadline.addingTimeInterval(-0.25)))
        precondition(state.remaining(at: deadline) == 0 && state.isFinished(at: deadline))
        precondition(!state.isRunning(at: deadline))
        precondition(state.remaining(at: deadline.addingTimeInterval(86_400)) == 0, "Expiry needs no UI ticks")
        let finished = state
        state.pause(at: deadline)
        precondition(state == finished, "Finished timers must not become paused-zero")
        state.start(at: deadline)
        precondition(state.phase == .running(deadline: deadline.addingTimeInterval(60)), "Start after finish begins the full duration")
        state.selectMode(.focus)
        precondition(state.phase == .running(deadline: deadline.addingTimeInterval(60)), "Reselecting a mode is a no-op")
        state.setMinutes(7, for: .rest)
        precondition(state.phase == .running(deadline: deadline.addingTimeInterval(60)), "Other-mode edits preserve the active timer")
        state.setMinutes(1, for: .focus)
        precondition(state.phase == .running(deadline: deadline.addingTimeInterval(60)), "Unchanged duration is a no-op")
        for invalid in [Int.min, 0, 181, Int.max] {
            let before = state
            state.setMinutes(invalid, for: .focus)
            state.setMinutes(invalid, for: .rest)
            precondition(state == before, "Invalid minutes must not mutate either mode")
        }
        state.setMinutes(180, for: .focus)
        precondition(state.phase == .idle && state.remaining(at: origin) == 10_800)
        state.start(at: origin)
        state.pause(at: origin.addingTimeInterval(1))
        state.setMinutes(1, for: .focus)
        precondition(state.phase == .idle && state.remaining(at: origin) == 60, "Editing a paused active duration resets it")
        state.start(at: origin)
        state.selectMode(.rest)
        precondition(state.phase == .idle && state.remaining(at: origin) == 420, "Mode changes reset without starting")
        state.start(at: origin)
        state.reset()
        precondition(state.mode == .rest && state.minutes(for: .focus) == 1 && state.minutes(for: .rest) == 7)
        precondition(state.phase == .idle && !state.isFinished(at: origin.addingTimeInterval(100_000)))

        // Fixed name so scripts/check.sh can delete the domain file afterwards.
        let suite = "local.browww.check.session-timer"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            defaults.synchronize()
        }
        let store = SessionTimerStore(defaults: defaults, notifier: { _ in nil })
        store.setMinutes(1, for: .focus)
        store.setMinutes(7, for: .rest)
        store.start(at: origin)
        try checkRestart(store: store, defaults: defaults, suite: suite,
                         now: origin.addingTimeInterval(10.25), remaining: 49.75, status: "running")
        store.pause(at: origin.addingTimeInterval(0.25))
        try checkRestart(store: store, defaults: defaults, suite: suite,
                         now: origin.addingTimeInterval(100_000), remaining: 59.75, status: "paused")
        store.start(at: origin.addingTimeInterval(100))
        try checkRestart(store: store, defaults: defaults, suite: suite,
                         now: origin.addingTimeInterval(1_000), remaining: 0, status: "finished")
        store.reset()
        let resetStore = SessionTimerStore(defaults: defaults)
        precondition(resetStore.state.phase == .idle && resetStore.state.remaining(at: origin) == 60)
        precondition(resetStore.state.minutes(for: .rest) == 7, "Reset preserves persisted settings")

        var calls: [String] = []
        var allowed = true
        let notified = SessionTimerStore(defaults: defaults, notifier: { state in
            guard case .running = state.phase else {
                calls.append("cancel")
                return nil
            }
            calls.append("schedule-start")
            try? await Task.sleep(for: .milliseconds(50))
            calls.append("schedule-end")
            return allowed
        })
        notified.start()
        try await waitUntil("Starting must schedule the finish notification") { calls == ["schedule-start"] }
        notified.pause()
        try await waitUntil("Pausing must cancel the notification") { calls.count == 3 }
        precondition(calls == ["schedule-start", "schedule-end", "cancel"], "A pause must not be overtaken by an older pending schedule")
        precondition(!notified.notificationsDenied)
        allowed = false
        notified.start()
        try await waitUntil("Resuming must schedule again") { calls.count == 5 }
        precondition(notified.notificationsDenied, "Denied notifications must be reported")
        notified.reset()
        try await waitUntil("Reset must cancel the notification") { calls.count == 6 }
        precondition(calls.last == "cancel" && notified.notificationsDenied, "Cancelling must not hide a denied permission")
        notified.reset()
        try await Task.sleep(for: .milliseconds(100))
        precondition(calls.count == 6, "No-op actions must not touch notifications")
        allowed = true
        notified.start()
        try await waitUntil("A later grant must clear the warning") { calls.count == 8 && !notified.notificationsDenied }
        notified.selectMode(.rest)
        try await waitUntil("Switching modes must cancel the running notification") { calls.count == 9 }
        precondition(calls.last == "cancel")
        notified.selectMode(.focus)
        try await waitUntil("Mode selection must settle") { calls.count == 10 }

        let validData = try JSONEncoder().encode(store.state)
        let validObject = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
        var invalidObjects: [[String: Any]] = []
        for (key, value) in [("focusMinutes", 0), ("focusMinutes", 181), ("breakMinutes", 0), ("breakMinutes", 181)] {
            var object = validObject
            object[key] = value
            invalidObjects.append(object)
        }
        for remaining in [0.0, -0.25, 60.25, "NaN", "Infinity", "-Infinity"] as [Any] {
            var object = validObject
            object["phase"] = ["paused": ["remaining": remaining]]
            invalidObjects.append(object)
        }
        for deadline in ["NaN", "Infinity", "-Infinity"] {
            var object = validObject
            object["phase"] = ["running": ["deadline": deadline]]
            invalidObjects.append(object)
        }
        var unknownMode = validObject
        unknownMode["mode"] = "unknown"
        invalidObjects.append(unknownMode)
        var missingPhase = validObject
        missingPhase.removeValue(forKey: "phase")
        invalidObjects.append(missingPhase)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        for object in invalidObjects {
            let data = try JSONSerialization.data(withJSONObject: object)
            precondition((try? decoder.decode(SessionTimerState.self, from: data)) == nil, "Invalid snapshots must fail model validation")
            defaults.set(data, forKey: "SessionTimer.state")
            precondition(SessionTimerStore(defaults: defaults).state == SessionTimerState(), "Invalid persistence must restore fresh idle")
        }
        for corrupt in [Data(), Data("not JSON".utf8), Data("{}".utf8)] {
            defaults.set(corrupt, forKey: "SessionTimer.state")
            precondition(SessionTimerStore(defaults: defaults).state == SessionTimerState())
        }
        defaults.set("wrong storage type", forKey: "SessionTimer.state")
        precondition(SessionTimerStore(defaults: defaults).state == SessionTimerState())
        defaults.removeObject(forKey: "SessionTimer.state")
        precondition(SessionTimerStore(defaults: defaults).state == SessionTimerState())

        for minutes in [1, 180] {
            var boundary = SessionTimerState()
            boundary.setMinutes(minutes, for: .focus)
            boundary.setMinutes(minutes, for: .rest)
            boundary.selectMode(.rest)
            boundary.start(at: origin)
            boundary.pause(at: origin)
            let data = try JSONEncoder().encode(boundary)
            defaults.set(data, forKey: "SessionTimer.state")
            precondition(SessionTimerStore(defaults: defaults).state == boundary, "Inclusive duration and paused-remainder boundaries must restore")
        }
        print("Session timer: deadline transitions, fractional pause/resume, duration boundaries, serialized notification scheduling/cancellation, fresh-process restoration and invalid persistence passed")
    }

    @MainActor
    private static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(condition(), message)
    }

    @MainActor
    private static func checkRestart(
        store: SessionTimerStore, defaults: UserDefaults, suite: String,
        now: Date, remaining: TimeInterval, status: String
    ) throws {
        defaults.synchronize()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = [
            "restore", suite, try JSONEncoder().encode(store.state).base64EncodedString(),
            String(now.timeIntervalSinceReferenceDate), String(remaining), status
        ]
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationStatus == 0, "Fresh-process \(status) restoration failed")
    }
}
#endif
