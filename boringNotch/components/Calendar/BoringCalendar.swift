//
//  BoringCalendar.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

struct Config: Equatable {
    //    var count: Int = 10  // 3 days past + today + 7 days future
    var past: Int = 7
    var future: Int = 14
    var steps: Int = 1  // Each step is one day
    var spacing: CGFloat = 0
    var showsText: Bool = true
    var offset: Int = 2  // Number of dates to the left of the selected date
}

struct WheelPicker: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var selectedDate: Date
    @State private var scrollPosition: Int?
    @State private var haptics: Bool = false
    @State private var byClick: Bool = false
    let config: Config

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: config.spacing) {
                let spacerNum = config.offset
                let dateCount = totalDateItems()
                let totalItems = dateCount + 2 * spacerNum
                ForEach(0..<totalItems, id: \.self) { index in
                    if index < spacerNum || index >= spacerNum + dateCount {
                        Spacer()
                            .frame(width: 28, height: 36)
                            .id(index)
                    } else {
                        let date = dateForItemIndex(index: index, spacerNum: spacerNum)
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        dateButton(date: date, isSelected: isSelected, id: index) {
                            selectedDate = date
                            byClick = true
                            scrollPosition = index
                            if Defaults[.enableHaptics] {
                                haptics.toggle()
                            }
                        }
                    }
                }
            }
            .frame(height: 40)
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .scrollTargetBehavior(.viewAligned)
        .sensoryFeedback(.alignment, trigger: haptics)
        .onChange(of: scrollPosition) { _, newValue in
            if !byClick {
                handleScrollChange(newValue: newValue, config: config)
            } else {
                byClick = false
            }
        }
        .onAppear {
            scrollToToday(config: config)
        }
        .onChange(of: selectedDate) { _, newValue in
            let targetIndex = indexForDate(newValue)
            if scrollPosition != targetIndex {
                byClick = true
                scrollPosition = targetIndex
            }
        }
    }

    private func dateButton(
        date: Date, isSelected: Bool, id: Int, onClick: @escaping () -> Void
    ) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let label = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return Button(action: onClick) {
            VStack(spacing: 1) {
                Text(dateToString(for: date))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 12, weight: isToday || isSelected ? .semibold : .regular))
                    .frame(width: 24, height: 20)
                    .background {
                        Circle()
                            .fill(isSelected ? Color.effectiveAccent : isToday ? Color.primary.opacity(0.14) : .clear)
                    }
            }
            .frame(width: 28, height: 36)
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "Selected" : "")
        .id(id)
    }

    func handleScrollChange(newValue: Int?, config: Config) {
        guard let newIndex = newValue else { return }
        let spacerNum = config.offset
        let dateCount = totalDateItems()
        guard (spacerNum..<(spacerNum + dateCount)).contains(newIndex) else { return }
        let date = dateForItemIndex(index: newIndex, spacerNum: spacerNum)
        if !Calendar.current.isDate(date, inSameDayAs: selectedDate) {
            selectedDate = date
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    private func scrollToToday(config: Config) {
        let today = Date()
        byClick = true
        scrollPosition = indexForDate(today)
        selectedDate = today
    }

    // MARK: - Index/Date mapping with steps and spacers
    private func indexForDate(_ date: Date) -> Int {
        let spacerNum = config.offset
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.startOfDay(for: cal.date(byAdding: .day, value: -config.past, to: today) ?? today)
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: startDate, to: target).day ?? 0
        let stepIndex = max(0, min(days / max(config.steps, 1), totalDateItems() - 1))
        return spacerNum + stepIndex
    }

    private func dateForItemIndex(index: Int, spacerNum: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -config.past, to: today) ?? today
        let stepIndex = index - spacerNum
        return cal.date(byAdding: .day, value: stepIndex * max(config.steps, 1), to: startDate) ?? today
    }

    private func totalDateItems() -> Int {
        let range = config.past + config.future
        let step = max(config.steps, 1)
        return Int(ceil(Double(range) / Double(step))) + 1
    }

    private func dateToString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}

struct CalendarView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.calendarApp) private var calendarApp
    @State private var selectedDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(selectedDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                dateNavigationButton(icon: "chevron.left", label: "Previous day", offset: -1)
                dateNavigationButton(icon: "calendar", label: "Today", offset: nil)
                dateNavigationButton(icon: "chevron.right", label: "Next day", offset: 1)
            }

            WheelPicker(selectedDate: $selectedDate, config: Config(past: 7, future: 14, spacing: 1, offset: 2))
                .frame(height: 40)

            let filteredEvents = EventListView.filteredEvents(events: calendarManager.events)
            if filteredEvents.isEmpty {
                EmptyEventsView(selectedDate: selectedDate, accessIsUnavailable: accessIsUnavailable)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EventListView(events: calendarManager.events)
            }
            if let error = calendarManager.calendarOpenError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                calendarManager.openCalendarApp()
            } label: {
                Label("Open \(calendarApp.rawValue)", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open \(calendarApp.rawValue)")
        }
        .onChange(of: selectedDate) {
            Task {
                await calendarManager.updateCurrentDate(selectedDate)
            }
        }
        .onChange(of: vm.notchState) { _, _ in
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
        .onAppear {
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
    }

    private var accessIsUnavailable: Bool {
        let calendarStatus = EKEventStore.authorizationStatus(for: .event)
        let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        return calendarStatus != .fullAccess && reminderStatus != .fullAccess
    }

    private func dateNavigationButton(icon: String, label: String, offset: Int?) -> some View {
        Button {
            if let offset {
                selectedDate = Calendar.current.date(byAdding: .day, value: offset, to: selectedDate) ?? selectedDate
            } else {
                selectedDate = Date.now
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct EmptyEventsView: View {
    let selectedDate: Date
    let accessIsUnavailable: Bool

    var body: some View {
        VStack(spacing: 5) {
            VStack(spacing: 3) {
                if !accessIsUnavailable {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(accessIsUnavailable ? "Calendar read access is required" : noEventsTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                if !accessIsUnavailable {
                    Text("Nothing scheduled.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            if accessIsUnavailable {
                Button {
                    SettingsWindowController.shared.showWindow(initialTab: "Calendar")
                } label: {
                    Text("Connect calendars…")
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .help("Allow Full Access in System Settings › Privacy & Security › Calendars.")
            }
        }
        .multilineTextAlignment(.center)
    }

    private var noEventsTitle: String {
        Calendar.current.isDateInToday(selectedDate) ? "No events or reminders today" : "No events or reminders"
    }
}

struct EventListView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var calendarManager = CalendarManager.shared
    let events: [EventModel]
    @Default(.autoScrollToNextEvent) private var autoScrollToNextEvent
    @Default(.showFullEventTitles) private var showFullEventTitles

    static func filteredEvents(events: [EventModel]) -> [EventModel] {
        events.filter { event in
            if event.type.isReminder, case .reminder(let completed) = event.type {
                return !completed || !Defaults[.hideCompletedReminders]
            }
            return !event.isAllDay || !Defaults[.hideAllDayEvents]
        }
    }

    private var filteredEvents: [EventModel] {
        Self.filteredEvents(events: events)
    }

    private func scrollToRelevantEvent(proxy: ScrollViewProxy) {
        guard autoScrollToNextEvent else { return }
        let now = Date()
        let target = filteredEvents.first(where: { !$0.isAllDay && $0.end > now })
            ?? filteredEvents.first(where: \.isAllDay)
            ?? filteredEvents.last
        guard let target else { return }

        Task { @MainActor in
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredEvents) { event in
                        Group {
                            if event.type.isReminder {
                                reminderRow(event)
                            } else {
                                eventButton(event)
                            }
                        }
                        .id(event.id)
                        if event.id != filteredEvents.last?.id {
                            Divider()
                                .overlay(.secondary.opacity(0.2))
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .onAppear {
                scrollToRelevantEvent(proxy: proxy)
            }
            .onChange(of: filteredEvents) { _, _ in
                scrollToRelevantEvent(proxy: proxy)
            }
        }
    }

    private func eventButton(_ event: EventModel) -> some View {
        Button {
            if let url = event.calendarAppURL() {
                openURL(url)
            }
        } label: {
            calendarEventRow(event)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .help("Open \(event.title) in \(event.calendarAppName)")
        .accessibilityLabel("Open \(event.title) in \(event.calendarAppName)")
    }

    private func reminderRow(_ event: EventModel) -> some View {
        let isCompleted: Bool
        if case .reminder(let completed) = event.type {
            isCompleted = completed
        } else {
            isCompleted = false
        }

        return HStack(spacing: 7) {
            ReminderToggle(
                isOn: Binding(
                    get: { isCompleted },
                    set: { completed in
                        Task {
                            await calendarManager.setReminderCompleted(
                                reminderID: event.id, completed: completed
                            )
                        }
                    }
                ),
                color: Color(event.calendar.color)
            )
            Button {
                if let url = event.calendarAppURL() {
                    openURL(url)
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(showFullEventTitles ? nil : 1)
                        if let location = event.location, !location.isEmpty {
                            Text(location)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    eventTime(event)
                }
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .help("Open \(event.title) in \(event.calendarAppName)")
            .accessibilityLabel("Open \(event.title) in \(event.calendarAppName)")
        }
        .opacity(isCompleted ? 0.45 : 1)
    }

    private func calendarEventRow(_ event: EventModel) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Capsule()
                .fill(Color(event.calendar.color))
                .frame(width: 3)
                .frame(minHeight: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(showFullEventTitles ? nil : 2)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            eventTime(event)
        }
        .opacity(event.eventStatus == .ended && Calendar.current.isDateInToday(event.start) ? 0.55 : 1)
    }

    @ViewBuilder
    private func eventTime(_ event: EventModel) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if event.isAllDay {
                Text("All-day")
            } else {
                Text(event.start, style: .time)
                if !event.type.isReminder {
                    Text(event.end, style: .time)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .frame(minWidth: 44, alignment: .trailing)
    }
}

struct ReminderToggle: View {
    @Binding var isOn: Bool
    var color: Color

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(color, lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(color)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Mark reminder incomplete" : "Mark reminder complete")
        .accessibilityLabel(isOn ? "Mark reminder incomplete" : "Mark reminder complete")
        .accessibilityValue(isOn ? "Completed" : "Incomplete")
    }
}

#Preview {
    CalendarView()
        .frame(width: 215, height: 130)
        .background(.black)
        .environmentObject(BoringViewModel())
}
