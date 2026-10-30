//
//  EventModel.swift
//  Calendr
//
//  Created by Paker on 24/12/20.
//  Original source: https://github.com/pakerwreah/Calendr
//  Modified by Alexander on 2025-05-18.
//

import Foundation
#if !CALENDAR_STANDALONE_CHECKS
import Defaults
#endif

struct EventModel: Equatable, Identifiable {
    let id: String
    let start: Date
    let end: Date
    let title: String
    let location: String?
    let notes: String?
    let url: URL?
    let isAllDay: Bool
    let type: EventType
    let calendar: CalendarModel
    let participants: [Participant]
    let timeZone: TimeZone?
    let hasRecurrenceRules: Bool
    let priority: Priority?
    let iCalUID: String?
    let accountEmail: String?
}

enum AttendanceStatus: Comparable {
    case accepted
    case maybe
    case pending
    case declined
    case unknown

    private var comparisonValue: Int {
        switch self {
        case .accepted: return 1
        case .maybe: return 2
        case .declined: return 3
        case .pending: return 4
        case .unknown: return 5
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        return lhs.comparisonValue < rhs.comparisonValue
    }
}

enum EventType: Equatable {
    case event(AttendanceStatus)
    case birthday
    case reminder(completed: Bool)
}

enum EventStatus: Equatable {
    case upcoming
    case inProgress
    case ended
}

extension EventType {
    var isEvent: Bool { if case .event = self { return true } else { return false } }
    var isBirthday: Bool { self ~= .birthday }
    var isReminder: Bool { if case .reminder = self { return true } else { return false } }
}

extension EventModel {
    
    var eventStatus: EventStatus {
        if start > Date() {
            return .upcoming
        } else if end > Date() {
            return .inProgress
        } else {
            return .ended
        }
    }
        
    var attendance: AttendanceStatus { if case .event(let attendance) = type { return attendance } else { return .unknown } }

    var isMeeting: Bool { !participants.isEmpty }


    #if !CALENDAR_STANDALONE_CHECKS
    private var notionAccountEmail: String? {
        let configured = Defaults[.notionCalendarAccountEmails][calendar.accountID] ?? ""
        return NotionCalendarLink.validEmail(configured) ?? accountEmail
    }

    var calendarAppName: String {
        if type.isReminder { return "Reminders" }
        if Defaults[.calendarApp] == .notion, notionAccountEmail != nil, iCalUID?.isEmpty == false {
            return "Notion Calendar"
        }
        return "Apple Calendar"
    }
    #endif
    func calendarAppURL() -> URL? {
        #if !CALENDAR_STANDALONE_CHECKS
        if !type.isReminder, Defaults[.calendarApp] == .notion,
           let email = notionAccountEmail, let iCalUID,
           let link = NotionCalendarLink.eventURL(
               accountEmail: email, iCalUID: iCalUID, start: start, end: end,
               isAllDay: isAllDay, timeZone: timeZone ?? .current, title: title
           ) {
            return link
        }
        #endif

        guard let id = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        guard !type.isReminder else {
            return URL(string: "x-apple-reminderkit://remcdreminder/\(id)")
        }

        let date: String
        if hasRecurrenceRules {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            if !isAllDay {
                formatter.timeZone = .init(secondsFromGMT: 0)
            }
            if let formattedDate = formatter.string(for: start) {
                date = "/\(formattedDate)"
            } else {
                return nil
            }
        } else {
            date =  ""
        }
        return URL(string: "ical://ekevent\(date)/\(id)?method=show&options=more")
    }
}

struct Participant: Hashable {
    let name: String
    let status: AttendanceStatus
    let isOrganizer: Bool
    let isCurrentUser: Bool
}

enum Priority {
    case high
    case medium
    case low
}

enum NotionCalendarLink {
    static func validEmail(_ value: String) -> String? {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !email.contains(where: \.isWhitespace) else { return nil }
        return email
    }

    static func eventURL(
        accountEmail: String, iCalUID: String, start: Date, end: Date,
        isAllDay: Bool, timeZone: TimeZone, title: String
    ) -> URL? {
        guard let email = validEmail(accountEmail), !iCalUID.isEmpty, end >= start else { return nil }
        let dateStyle = Date.ISO8601FormatStyle(timeZone: timeZone)
            .year().month().day().dateSeparator(.dash)
        var components = URLComponents()
        components.scheme = "cron"
        components.host = "showEvent"
        components.queryItems = [
            URLQueryItem(name: "accountEmail", value: email),
            URLQueryItem(name: "iCalUID", value: iCalUID),
            URLQueryItem(name: "startDate", value: isAllDay ? start.formatted(dateStyle) : start.formatted(.iso8601)),
            URLQueryItem(name: "endDate", value: isAllDay ? end.formatted(dateStyle) : end.formatted(.iso8601)),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "ref", value: "local.browww")
        ]
        // Query parsers treat a literal plus as a space; preserve aliases and UIDs.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
