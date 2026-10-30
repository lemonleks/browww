import Foundation

@main
struct CalendarLinkCheck {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_790_777_400)
        let end = start.addingTimeInterval(1800)
        let email = "work+calendar@example.com"
        let uid = "event+42&title=wrong/☃@google.com"
        let title = "Planning & review + 50%"
        let link = NotionCalendarLink.eventURL(
            accountEmail: email, iCalUID: uid, start: start, end: end,
            isAllDay: false, timeZone: .current, title: title
        )!
        let components = URLComponents(url: link, resolvingAgainstBaseURL: false)!
        let values = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        precondition(components.scheme == "cron" && components.host == "showEvent")
        precondition(values["accountEmail"] == email)
        precondition(values["iCalUID"] == uid && values["title"] == title)
        precondition(values["ref"] == "local.browww" && values.count == 6)
        precondition(!components.percentEncodedQuery!.contains("+"))
        let formatter = ISO8601DateFormatter()
        precondition(formatter.date(from: values["startDate"]!) == start)
        precondition(formatter.date(from: values["endDate"]!) == end)

        let midnight = formatter.date(from: "2026-09-30T14:00:00Z")!
        let allDay = NotionCalendarLink.eventURL(
            accountEmail: email, iCalUID: "all-day", start: midnight,
            end: midnight.addingTimeInterval(86_400), isAllDay: true,
            timeZone: TimeZone(secondsFromGMT: 36_000)!, title: "All day"
        )!
        let dates = Dictionary(uniqueKeysWithValues: URLComponents(url: allDay, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        precondition(dates["startDate"] == "2026-10-01" && dates["endDate"] == "2026-10-02")

        for invalid in ["", "not an email", "wrong@@example.com", "work@example.com\nother@example.com"] {
            precondition(NotionCalendarLink.eventURL(
                accountEmail: invalid, iCalUID: uid, start: start, end: end,
                isAllDay: false, timeZone: .current, title: title
            ) == nil)
        }
        precondition(NotionCalendarLink.eventURL(
            accountEmail: email, iCalUID: "", start: start, end: end,
            isAllDay: false, timeZone: .current, title: title
        ) == nil)
        precondition(NotionCalendarLink.eventURL(
            accountEmail: email, iCalUID: uid, start: end, end: start,
            isAllDay: false, timeZone: .current, title: title
        ) == nil)
        print("Calendar links: exact event/account identity, query escaping, timed/all-day dates and invalid metadata passed.")
    }
}
