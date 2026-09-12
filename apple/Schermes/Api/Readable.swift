import Foundation

/// A cron expression in words, or nil when words would not say exactly what it does. Nil is
/// always safe to show; a sentence that disagrees with the expression beside it is not.
///
/// The dialect is croner's, which is what the daemon parses with: five fields, six with seconds
/// in front, seven with a year behind, or a nickname. Anything these words cannot carry — a
/// seconds field that is not zero, a year, `L`, `W`, `#`, `?`, croner's `+` — reads as nil.
func cadence(_ cron: String) -> String? {
    var fields = cron.uppercased().split(whereSeparator: \.isWhitespace).map(String.init)
    if fields.count == 1, let expanded = nicknames[fields[0]] {
        fields = expanded.split(separator: " ").map(String.init)
    }
    if fields.count == 7 {
        guard fields.removeLast() == "*" else { return nil }
    }
    if fields.count == 6 {
        guard fields.removeFirst() == "0" else { return nil }
    }
    guard fields.count == 5,
          let minutes = expand(fields[0], 0...59),
          let hours = expand(fields[1], 0...23),
          let days = expand(fields[2], 1...31),
          let months = expand(fields[3], 1...12, names: monthAbbreviations),
          let weekdays = expand(fields[4], 0...7, names: dayAbbreviations).map({ Set($0.map { $0 % 7 }) }),
          let time = timeOfDay(minutes.sorted(), hours.sorted())
    else { return nil }

    // croner's rule, as Vixie cron's: when neither day field is a bare `*` a day matches either
    // one, so a restricted field that already covers every day leaves nothing out.
    let byDay = fields[2] != "*", byWeekday = fields[4] != "*"
    let anyDay = (byDay && days.count == 31) || (byWeekday && weekdays.count == 7)

    var on: [String] = []
    var monthNamed = false
    if !anyDay, byDay {
        guard days.count <= 4 else { return nil }
        var place = "the month"
        if !byWeekday, fields[3] != "*", months.count == 1, let month = months.first {
            place = monthNames[month - 1]
            monthNamed = true
        }
        on.append("on the \(joined(days.sorted().map(ordinal))) of \(place)")
    }
    if !anyDay, byWeekday {
        let mondayFirst = weekdays.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }
        on.append(weekdays == [1, 2, 3, 4, 5] ? "on weekdays" : "on " + joined(mondayFirst.map { weekdayNames[$0] }))
    }

    let when = on.joined(separator: " and ")
    var parts = time.listed ? [when.isEmpty ? "every day" : when, time.words] : [time.words, when]
    if fields[3] != "*", months.count < 12, !monthNamed {
        let sorted = months.sorted()
        if sorted.count > 2, let span = run(sorted) {
            parts.append("from \(monthNames[span.first - 1]) to \(monthNames[span.last - 1])")
        } else {
            parts.append("in " + joined(sorted.map { monthNames[$0 - 1] }))
        }
    }
    return parts.filter { !$0.isEmpty }.joined(separator: " ")
}

/// `listed` is a handful of clock times, which want a day in front of them ("every day at 09:00");
/// anything else already says how often it comes round.
private func timeOfDay(_ minutes: [Int], _ hours: [Int]) -> (words: String, listed: Bool)? {
    let everyHour = hours.count == 24
    let span = run(hours)

    if minutes.count == 60 {
        if everyHour { return ("every minute", false) }
        guard let span else { return nil }
        return ("every minute from \(clock(span.first, 0)) to \(clock(span.last, 59))", false)
    }
    if let step = period(minutes, in: 60) {
        if everyHour { return ("every \(step) minutes", false) }
        guard let span, let first = minutes.first, let last = minutes.last else { return nil }
        return ("every \(step) minutes from \(clock(span.first, first)) to \(clock(span.last, last))", false)
    }
    if minutes.count * hours.count <= 4 {
        return ("at " + joined(hours.flatMap { hour in minutes.map { clock(hour, $0) } }), true)
    }
    if everyHour {
        guard minutes.count <= 4 else { return nil }
        return (minutes == [0] ? "every hour" : "every hour at " + joined(minutes.map { ":" + pad($0) }), false)
    }
    guard minutes.count == 1, let minute = minutes.first, let hour = hours.first else { return nil }
    if let step = period(hours, in: 24) {
        let first = clock(hour, minute)
        return (first == "00:00" ? "every \(step) hours" : "every \(step) hours from \(first)", false)
    }
    guard let span else { return nil }
    return ("every hour from \(clock(span.first, minute)) to \(clock(span.last, minute))", false)
}

/// Every value in a field, or nil for syntax croner accepts that these words do not cover.
private func expand(_ field: String, _ range: ClosedRange<Int>, names: [String] = []) -> Set<Int>? {
    guard field.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "*,-/".contains($0)) })
    else { return nil }

    var values = Set<Int>()
    for part in field.split(separator: ",", omittingEmptySubsequences: false) {
        let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let step = pieces.count == 2 ? Int(pieces[1]) : 1, step > 0
        else { return nil }

        let span: ClosedRange<Int>
        if pieces[0] == "*" {
            span = range
        } else {
            let ends = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
            // croner refuses `5/15`: a step needs a wildcard or a range in front of it.
            guard ends.count == 2 || (ends.count == 1 && pieces.count == 1),
                  let low = value(ends[0], range, names),
                  let high = value(ends[ends.count - 1], range, names),
                  low <= high
            else { return nil }
            span = low...high
        }
        values.formUnion(stride(from: span.lowerBound, through: span.upperBound, by: step))
    }
    return values
}

private func value(_ text: Substring, _ range: ClosedRange<Int>, _ names: [String]) -> Int? {
    guard let number = Int(text) ?? names.firstIndex(of: String(text)).map({ $0 + range.lowerBound }),
          range.contains(number)
    else { return nil }
    return number
}

/// Evenly spaced round the whole range — every 15 minutes, every 2 hours. A step that does not
/// divide the hour, like `*/7`, has a short gap at the top of it and is not "every 7 minutes".
private func period(_ sorted: [Int], in size: Int) -> Int? {
    guard sorted.count > 1, size % sorted.count == 0, let first = sorted.first else { return nil }
    let step = size / sorted.count
    return sorted.enumerated().allSatisfy { $0.element == first + $0.offset * step } ? step : nil
}

private func run(_ sorted: [Int]) -> (first: Int, last: Int)? {
    guard let first = sorted.first, let last = sorted.last, last - first == sorted.count - 1 else { return nil }
    return (first, last)
}

/// Twenty-four hour, as the expression beside it is.
private func clock(_ hour: Int, _ minute: Int) -> String { pad(hour) + ":" + pad(minute) }

private func pad(_ number: Int) -> String { number < 10 ? "0\(number)" : "\(number)" }

private func ordinal(_ number: Int) -> String {
    let suffix = (11...13).contains(number % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][number % 10, default: "th"]
    return "\(number)\(suffix)"
}

/// By hand rather than `ListFormatStyle`, which follows the device's locale and would put a Dutch
/// "en" in the middle of an English sentence.
private func joined(_ items: [String]) -> String {
    guard let last = items.last, items.count > 1 else { return items.joined() }
    return items.dropLast().joined(separator: ", ") + " and " + last
}

private let nicknames = [
    "@YEARLY": "0 0 1 1 *", "@ANNUALLY": "0 0 1 1 *", "@MONTHLY": "0 0 1 * *",
    "@WEEKLY": "0 0 * * 0", "@DAILY": "0 0 * * *", "@MIDNIGHT": "0 0 * * *", "@HOURLY": "0 * * * *",
]
private let monthAbbreviations = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
private let dayAbbreviations = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
private let monthNames = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
]
private let weekdayNames = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]

// MARK: - Activity

/// One line of an agent's activity, built from the fields that matter to its type. The daemon
/// keeps these payloads small on purpose; a field that is missing gets a plainer sentence, never
/// a dump of what is there.
func sentence(for event: ExecutionEvent) -> String {
    let data = event.data
    switch event.type {
    case .state:
        guard let state = data.text("to").flatMap(AgentState.init(rawValue:)) else { return "Changed state" }
        return "Now \(state.label)"

    case .tool_call:
        if let command = data.text("command") { return "Ran “\(command)”" }
        if let action = data.text("action"), let line = actions[action] { return line }
        return "Called \(data.text("tool") ?? "a tool")"

    case .tool_result:
        return result(data)

    case .failure:
        return data.text("message").map { "The turn failed: \($0)" } ?? "The turn failed"

    case .restart:
        var line = "The daemon restarted"
        if let state = data.text("from").flatMap(AgentState.init(rawValue:)) { line += " while it was \(state.label)" }
        if case .array(let calls)? = data["interrupted"], !calls.isEmpty {
            line += " and cut off \(counted(calls.count, "tool call"))"
        }
        if data.flag("worker") == true { line += ", so the worker was given up" }
        return line

    case .control:
        guard let held = data.flag("held") else { return "The mouse and keyboard changed hands" }
        return held ? "You took the mouse and keyboard" : "You gave the mouse and keyboard back"

    case .schedule_dropped:
        let which = data.int("schedule").map { "schedule \($0)" } ?? "a schedule"
        let cron = data.text("cron").map { " (“\($0)”)" } ?? ""
        return "Dropped \(which)\(cron): it has no next run left"

    case .approval:
        let what = data.text("kind") == "conversation"
            ? "a thread"
            : data.text("target").map { "the agent \($0)" } ?? "something"
        guard let approved = data.flag("approved") else { return "Asked you to delete \(what)" }
        return approved ? "You approved deleting \(what)" : "You refused to delete \(what)"
    }
}

/// A result carries no tool name, only the fields its tool reports, so it is read by which of
/// those are present. The three schedule tools differ by nothing else: `cron` and `paused` are
/// asked about before a bare `schedule`.
private func result(_ data: [String: JSONValue]) -> String {
    if data.flag("ok") == false { return "Failed: \(data.text("error") ?? "no reason given")" }
    if data.flag("timedOut") == true { return "The command timed out" }
    if let code = data.int("exitCode") { return "The command exited with code \(code)" }
    if data["imageBytes"] != nil { return "Got the screenshot" }
    if let worker = data.text("worker") { return "Started task worker \(worker)" }
    if let to = data.text("to") { return "Delivered a message to \(to)" }
    if let results = data.int("results") {
        return "Found \(counted(results, "result"))" + (data.text("host").map { " on \($0)" } ?? "")
    }
    if let status = data.int("status") {
        return "Fetched \(data.text("host") ?? "a page"): HTTP \(status)" + (data.int("chars").map { ", \($0) characters" } ?? "")
    }
    if let scope = data.text("scope") { return "Saved to its \(scope) memory" }
    if let held = data.int("schedules") { return "Listed \(counted(held, "schedule"))" }
    if let id = data.int("schedule") {
        if let cron = data.text("cron") { return "Scheduled \(id) as “\(cron)”" }
        if let paused = data.flag("paused") { return paused ? "Paused schedule \(id)" : "Resumed schedule \(id)" }
        return "Cancelled schedule \(id)"
    }
    if let chars = data.int("chars") {
        return "Got \(counted(chars, "character"))" + (data.text("host").map { " from \($0)" } ?? " back")
    }
    return "Done"
}

private let actions = [
    "screenshot": "Took a screenshot",
    "move": "Moved the pointer",
    "click": "Clicked",
    "drag": "Dragged the pointer",
    "scroll": "Scrolled",
    "type": "Typed",
    "key": "Pressed keys",
    "clipboard_read": "Read the clipboard",
    "clipboard_write": "Wrote to the clipboard",
    "navigate": "Opened a page in the browser",
    "read": "Read the page in the browser",
    "evaluate": "Ran a script in the browser",
]

private func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

private extension Dictionary where Key == String, Value == JSONValue {
    func text(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        guard case .number(let value)? = self[key] else { return nil }
        return Int(value)
    }

    func flag(_ key: String) -> Bool? {
        guard case .bool(let value)? = self[key] else { return nil }
        return value
    }
}
