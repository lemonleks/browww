import SwiftUI

@MainActor
struct SessionTimerView: View {
    @ObservedObject private var store: SessionTimerStore

    init(store: SessionTimerStore? = nil) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let pausesTimer = store.state.isRunning(at: timeline.date)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Text("Session timer")
                        .font(.subheadline.weight(.semibold))

                    Spacer(minLength: 0)

                    Picker("Timer mode", selection: Binding(
                        get: { store.state.mode },
                        set: { store.selectMode($0) }
                    )) {
                        Text("Focus").tag(SessionTimerState.Mode.focus)
                        Text("Break").tag(SessionTimerState.Mode.rest)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Timer mode")
                    .accessibilityIdentifier("sessionTimer.mode")
                    .help("Switching modes resets the timer without starting it.")
                }

                HStack(alignment: .center, spacing: 24) {
                    countdown(at: timeline.date)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        Stepper(value: Binding(
                            get: { store.state.minutes(for: store.state.mode) },
                            set: { store.setMinutes($0, for: store.state.mode) }
                        ), in: 1...180) {
                            HStack(spacing: 8) {
                                Text("\(modeTitle) duration")
                                Spacer(minLength: 0)
                                Text("\(store.state.minutes(for: store.state.mode)) min")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(store.state.isRunning(at: timeline.date))
                        .accessibilityLabel("\(modeTitle) duration")
                        .accessibilityValue("\(store.state.minutes(for: store.state.mode)) minutes")
                        .accessibilityIdentifier("sessionTimer.minutes")
                        .help("Changing the duration resets this timer. Pause before editing.")

                        HStack(spacing: 8) {
                            Button(primaryActionTitle(at: timeline.date)) {
                                let now = Date()
                                if pausesTimer {
                                    store.pause(at: now)
                                } else {
                                    store.start(at: now)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("sessionTimer.primaryAction")

                            Button("Reset") {
                                store.reset()
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Reset timer")
                            .accessibilityIdentifier("sessionTimer.reset")
                        }
                    }
                    .frame(width: 252)
                }
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var modeTitle: String {
        store.state.mode == .focus ? "Focus" : "Break"
    }

    private func countdown(at now: Date) -> some View {
        let seconds = Int(store.state.remaining(at: now).rounded(.up))
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 52, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityLabel("\(modeTitle) time remaining")
                .accessibilityValue("\(seconds / 60) minutes, \(seconds % 60) seconds")
                .accessibilityIdentifier("sessionTimer.remaining")

            Text(status(at: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Timer status")
                .accessibilityValue(status(at: now))
                .accessibilityIdentifier("sessionTimer.status")

            if store.notificationsDenied {
                Text("Notifications are off for Browww in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func status(at now: Date) -> String {
        if store.state.isFinished(at: now) { return "Finished" }
        switch store.state.phase {
        case .idle: return "Ready"
        case .running: return "Running"
        case .paused: return "Paused"
        }
    }

    private func primaryActionTitle(at now: Date) -> String {
        if store.state.isRunning(at: now) { return "Pause" }
        if case .paused = store.state.phase { return "Resume" }
        return "Start"
    }
}
