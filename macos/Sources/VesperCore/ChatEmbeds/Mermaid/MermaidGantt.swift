import CoreGraphics
import Foundation

/// `gantt`: sections of tasks on a date axis, with `title`, `dateFormat`, `axisFormat`,
/// `tickInterval`, `excludes`/`includes`, `inclusiveEndDates` and the `done`/`active`/`crit`/
/// `milestone` tags. Tasks start at a date, `after` other tasks, or where the previous one ended,
/// and end at a date, `until` another task, or after a duration.
///
/// All date maths is on a proleptic Gregorian calendar in UTC done by hand, never `Calendar` or
/// `Date()`, so the picture doesn't depend on the Mac's time zone, locale or clock. That's also why
/// `todayMarker` is accepted but no today line is drawn, and why a first task with no start date
/// is a syntax error where mermaid would start it today. Excluded days lengthen tasks given a
/// duration, as in mermaid, but aren't shaded. `topAxis`, `weekday`, `weekend`, `displayMode` and
/// `click` are accepted and ignored.
struct MermaidGantt {
    struct Task {
        var name: String
        var section: Int
        var done = false, active = false, crit = false, milestone = false
        var start: Int64 = 0
        var end: Int64 = 0
    }

    var title: String?
    /// Section names; the first is the unnamed one that tasks before any `section` line sit in.
    var sections: [String] = [""]
    var tasks: [Task] = []
    var axisFormat: String?
    var tickInterval: GanttTime.Step?

    // MARK: Parsing

    private enum StartSpec { case date(Int64), after([String]), previous }
    private enum EndSpec { case date(Int64), duration(GanttTime.Duration), until([String]) }

    private struct RawTask {
        var task: Task
        var id: String?
        var start: StartSpec
        var end: EndSpec
        var line: Int
    }

    private static let tags: Set<String> = ["done", "active", "crit", "milestone"]

    static func parse(_ doc: MermaidSource) throws(NativeMermaidError) -> MermaidGantt {
        var g = MermaidGantt()
        g.title = doc.title
        var format = GanttDateFormat("YYYY-MM-DD")
        var excludes: [(String, Int)] = []
        var includes: [(String, Int)] = []
        var inclusiveEnd = false
        var raw: [RawTask] = []
        var skippingBlock = false
        for stmt in MermaidScan.statements(doc.lines, headerRest: doc.headerRest, headerLine: doc.headerLine) {
            let t = stmt.text
            if skippingBlock {
                if t.contains("}") { skippingBlock = false }
                continue
            }
            if t.hasPrefix("accTitle") || t.hasPrefix("accDescr") {
                // `accDescr {` opens a multi-line description that runs to the closing brace.
                if t.contains("{"), !t.contains("}") { skippingBlock = true }
                continue
            }
            if let rest = MermaidScan.keyword(t, "title") { if !rest.isEmpty { g.title = rest }; continue }
            if let rest = MermaidScan.keyword(t, "dateFormat") {
                if !rest.isEmpty { format = GanttDateFormat(rest) }
                continue
            }
            if let rest = MermaidScan.keyword(t, "axisFormat") { g.axisFormat = rest.isEmpty ? nil : rest; continue }
            if let rest = MermaidScan.keyword(t, "tickInterval") {
                guard let step = GanttTime.Step(tickInterval: rest) else {
                    throw .syntax(line: stmt.number, message: "tickInterval is a number and a unit, like 1week")
                }
                g.tickInterval = step
                continue
            }
            if let rest = MermaidScan.keyword(t, "excludes") { excludes += Self.dayList(rest, line: stmt.number); continue }
            if let rest = MermaidScan.keyword(t, "includes") { includes += Self.dayList(rest, line: stmt.number); continue }
            if MermaidScan.keyword(t, "inclusiveEndDates") != nil { inclusiveEnd = true; continue }
            if ["todayMarker", "topAxis", "weekday", "weekend", "displayMode", "click"].contains(where: { MermaidScan.keyword(t, $0) != nil }) {
                continue
            }
            // Section names can't contain a colon, so `Section review : …` is a task.
            if let rest = MermaidScan.keyword(t, "section"), !rest.contains(":") {
                g.sections.append(rest)
                continue
            }
            raw.append(try parseTask(t, line: stmt.number, section: g.sections.count - 1, format: format, inclusiveEnd: inclusiveEnd))
            if raw.count > NativeMermaid.maxRows { throw .tooLarge }
        }
        guard !raw.isEmpty else { throw .syntax(line: doc.headerLine, message: "the gantt chart has no tasks") }
        let calendar = try GanttExclusions(excludes: excludes, includes: includes, format: format)
        g.tasks = try resolve(raw, calendar: calendar)
        return g
    }

    /// `weekends, monday 2024-01-15` → the words with their line, parsed once the date format is known.
    private static func dayList(_ s: String, line: Int) -> [(String, Int)] {
        s.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).map { (String($0), line) }
    }

    /// `Name :[tags,] [id,] [start,] end`, with mermaid's rule for which fields are which: one
    /// field is the end, two are start and end, three are id, start and end.
    private static func parseTask(_ t: String, line: Int, section: Int, format: GanttDateFormat, inclusiveEnd: Bool) throws(NativeMermaidError) -> RawTask {
        guard let colon = t.firstIndex(of: ":") else {
            throw .syntax(line: line, message: "expected a task like Design : 2024-01-01, 3d")
        }
        let name = MermaidText.collapse(String(t[..<colon]))
        guard !name.isEmpty else { throw .syntax(line: line, message: "a task needs a name before the colon") }
        var fields = t[t.index(after: colon)...].split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var task = Task(name: name, section: section)
        while let first = fields.first, tags.contains(first.lowercased()), fields.count > 1 {
            switch first.lowercased() {
            case "done": task.done = true
            case "active": task.active = true
            case "crit": task.crit = true
            default: task.milestone = true
            }
            fields.removeFirst()
        }
        guard (1...3).contains(fields.count), !fields.contains(where: \.isEmpty) else {
            throw .syntax(line: line, message: "a task's data is [tags,] [id,] [start,] end, like a1, 2024-01-01, 3d")
        }
        var id: String?
        if fields.count == 3 { id = fields.removeFirst() }
        let start: StartSpec
        if fields.count == 2 {
            let s = fields.removeFirst()
            if let ids = MermaidScan.keyword(s, "after") {
                let list = ids.split(separator: " ").map(String.init)
                guard !list.isEmpty else { throw .syntax(line: line, message: "after needs a task id") }
                start = .after(list)
            } else if let ms = format.parse(s) ?? GanttDateFormat.iso(s) {
                start = .date(ms)
            } else {
                throw .syntax(line: line, message: "\"\(s)\" isn't a date in \(format.pattern) or after <id>")
            }
        } else {
            start = .previous
        }
        let e = fields[0]
        let end: EndSpec
        if let ids = MermaidScan.keyword(e, "until") {
            let list = ids.split(separator: " ").map(String.init)
            guard !list.isEmpty else { throw .syntax(line: line, message: "until needs a task id") }
            end = .until(list)
        } else if let ms = format.parse(e) ?? GanttDateFormat.iso(e) {
            end = .date(inclusiveEnd ? ms + GanttTime.day : ms)
        } else if let d = GanttTime.Duration(e) {
            end = .duration(d)
        } else {
            throw .syntax(line: line, message: "\"\(e)\" isn't a date in \(format.pattern) or a duration like 3d")
        }
        return RawTask(task: task, id: id, start: start, end: end, line: line)
    }

    /// Start and end times, resolving `after`/`until` references in any order (mermaid allows
    /// forward references) and reporting a cycle as a syntax error on the task that closes it.
    private static func resolve(_ raw: [RawTask], calendar: GanttExclusions) throws(NativeMermaidError) -> [Task] {
        var byID: [String: Int] = [:]
        for (i, r) in raw.enumerated() { if let id = r.id, byID[id] == nil { byID[id] = i } }
        enum State { case pending, resolving, done(Int64, Int64) }
        var state = Array(repeating: State.pending, count: raw.count)

        func times(_ i: Int) throws(NativeMermaidError) -> (Int64, Int64) {
            switch state[i] {
            case let .done(s, e): return (s, e)
            case .resolving: throw .syntax(line: raw[i].line, message: "task dependencies form a cycle")
            case .pending: break
            }
            state[i] = .resolving
            let r = raw[i]
            func lookup(_ id: String) throws(NativeMermaidError) -> Int {
                guard let j = byID[id] else { throw .syntax(line: r.line, message: "no task has the id \"\(id)\"") }
                return j
            }
            let start: Int64
            switch r.start {
            case let .date(ms): start = ms
            case let .after(ids):
                var latest = Int64.min
                for id in ids { latest = max(latest, try times(try lookup(id)).1) }
                start = latest
            case .previous:
                guard i > 0 else { throw .syntax(line: r.line, message: "the first task needs a start date") }
                start = try times(i - 1).1
            }
            var end: Int64
            switch r.end {
            case let .date(ms): end = ms
            case let .duration(d): end = try calendar.extend(start: start, end: d.added(to: start), line: r.line)
            case let .until(ids):
                var earliest = Int64.max
                for id in ids { earliest = min(earliest, try times(try lookup(id)).0) }
                end = earliest
            }
            // An end before the start draws nothing sensible; mermaid draws it inverted, this pins it.
            end = max(end, start)
            state[i] = .done(start, end)
            return (start, end)
        }

        var out: [Task] = []
        for i in raw.indices {
            var t = raw[i].task
            (t.start, t.end) = try times(i)
            out.append(t)
        }
        return out
    }

    // MARK: Layout and drawing

    static let chartWidth = 800.0
    static let rowHeight = 28.0
    static let barHeight = 20.0
    static let sectionSize = 13.0
    static let minLabelColumn = 80.0
    static let maxLabelColumn = 200.0

    func draw(_ theme: MermaidTheme) -> MermaidDrawing {
        let small = MermaidText.smallSize
        let lhSection = MermaidText.lineHeight(Self.sectionSize)
        let sectionLines = sections.map { MermaidText.lines($0).filter { !$0.isEmpty } }
        let widest = sectionLines.flatMap { $0 }.map { MermaidText.width($0, size: Self.sectionSize, bold: true) }.max() ?? 0
        let labelColumn = min(max(widest + 20, Self.minLabelColumn), Self.maxLabelColumn)
        let wrapped = sectionLines.map { MermaidText.wrap($0, maxWidth: labelColumn - 16, size: Self.sectionSize, bold: true) }

        var lo = tasks.map(\.start).min() ?? 0
        var hi = tasks.map(\.end).max() ?? 0
        if hi - lo < GanttTime.minute {
            lo -= GanttTime.day / 2
            hi += GanttTime.day / 2
        }
        let span = Double(hi - lo)
        let left = labelColumn
        func x(_ t: Int64) -> Double { left + Double(t - lo) / span * Self.chartWidth }

        // Rows: each section's tasks in source order, the band tall enough for its wrapped name.
        var bands: [(top: Double, height: Double, section: Int)] = []
        var rowTop: [Double] = Array(repeating: 0, count: tasks.count)
        var y = 0.0
        for s in sections.indices {
            let members = tasks.indices.filter { tasks[$0].section == s }
            guard !members.isEmpty || !sections[s].isEmpty else { continue }
            for (k, i) in members.enumerated() { rowTop[i] = y + Double(k) * Self.rowHeight }
            let h = max(Double(members.count) * Self.rowHeight, lhSection * Double(wrapped[s].count) + 8)
            bands.append((y, h, s))
            y += h
        }
        let rowsBottom = y

        let ticks = GanttTime.ticks(from: lo, to: hi, width: Self.chartWidth, fixed: tickInterval, format: axisFormat)
        let tickLabels = ticks.times.map { GanttTime.format($0, ticks.format) }
        let tickOverhang = (tickLabels.last.map { MermaidText.width($0, size: small) / 2 } ?? 0)

        var svg = MermaidSVG(theme: theme)
        var body: [(inout MermaidSVG) -> Void] = []
        var frames: [CGRect] = []
        var right = left + Self.chartWidth + tickOverhang

        for (i, t) in tasks.enumerated() {
            let (fill, fillOpacity, stroke) = Self.paint(t, theme)
            let textColor = fillOpacity == nil ? theme.ink(on: fill) : theme.text
            let mid = rowTop[i] + Self.rowHeight / 2
            let labelWidth = MermaidText.width(t.name, size: small)
            if t.milestone {
                let cx = (x(t.start) + x(t.end)) / 2, r = Self.barHeight / 2 + 1
                frames.append(CGRect(x: cx - r, y: mid - r, width: 2 * r, height: 2 * r))
                let labelX = cx + r + 6
                right = max(right, labelX + labelWidth)
                body.append { s in
                    s.polygon([CGPoint(x: cx, y: mid - r), CGPoint(x: cx + r, y: mid), CGPoint(x: cx, y: mid + r), CGPoint(x: cx - r, y: mid)],
                              fill: fill, stroke: stroke, strokeWidth: stroke == nil ? nil : 1.5)
                    s.text(t.name, x: labelX, y: mid, anchor: "start", size: small)
                }
                continue
            }
            let x0 = x(t.start), w = max(x(t.end) - x0, 2)
            let bar = CGRect(x: x0, y: mid - Self.barHeight / 2, width: w, height: Self.barHeight)
            frames.append(bar)
            // Inside when it fits, else after the bar, or before it when that would run past the axis.
            let label: (x: Double, anchor: String, color: String)
            if labelWidth + 12 <= w {
                label = (bar.midX, "middle", textColor)
            } else if bar.maxX + 6 + labelWidth > left + Self.chartWidth, bar.minX - 6 - labelWidth >= left {
                label = (bar.minX - 6, "end", theme.text)
            } else {
                label = (bar.maxX + 6, "start", theme.text)
                right = max(right, bar.maxX + 6 + labelWidth)
            }
            body.append { s in
                s.rect(bar, rx: 3, fill: fill, stroke: stroke, strokeWidth: stroke == nil ? nil : 1.5, fillOpacity: fillOpacity)
                s.text(t.name, x: label.x, y: mid, anchor: label.anchor, size: small, fill: label.color)
            }
        }

        let axisHeight = 8 + MermaidText.lineHeight(small) + 4
        let size = svg.beginDiagram(content: CGSize(width: right, height: rowsBottom + axisHeight), title: title)
        for (k, b) in bands.enumerated() where k % 2 == 0 {
            svg.rect(CGRect(x: 0, y: b.top, width: left + Self.chartWidth, height: b.height), fill: theme.noteFill)
        }
        for b in bands where !wrapped[b.section].isEmpty {
            let lines = wrapped[b.section]
            svg.lines(lines, x: 8, top: b.top + b.height / 2 - lhSection * Double(lines.count) / 2, anchor: "start",
                      size: Self.sectionSize, bold: true)
        }
        for (i, t) in ticks.times.enumerated() {
            let tx = x(t)
            svg.line(CGPoint(x: tx, y: 0), CGPoint(x: tx, y: rowsBottom), stroke: theme.line, width: 0.75, dash: "2 3")
            svg.line(CGPoint(x: tx, y: rowsBottom), CGPoint(x: tx, y: rowsBottom + 5), stroke: theme.muted)
            svg.text(tickLabels[i], x: tx, y: rowsBottom + 8 + MermaidText.lineHeight(small) / 2, size: small, fill: theme.muted)
        }
        svg.line(CGPoint(x: left, y: rowsBottom), CGPoint(x: left + Self.chartWidth, y: rowsBottom), stroke: theme.muted)
        for draw in body { draw(&svg) }
        svg.endDiagram()
        return MermaidDrawing(svg: svg.document(size: size, title: title), nodeFrames: frames, texts: svg.texts)
    }

    /// Bar colours by state: plain in the first series colour, critical in the last (red in both
    /// palettes), active as a tint of either with a solid outline, done in the neutral line colour
    /// (outlined red when it was critical).
    private static func paint(_ t: Task, _ theme: MermaidTheme) -> (fill: String, fillOpacity: Double?, stroke: String?) {
        let accent = t.crit ? theme.series(7) : theme.series(0)
        if t.done { return (theme.line, nil, t.crit ? accent : nil) }
        if t.active { return (accent, 0.25, accent) }
        return (accent, nil, nil)
    }
}

/// Excluded days (`excludes weekends, friday, 2024-01-15`) with `includes` overriding them.
struct GanttExclusions {
    var weekdays: Set<Int> = []
    var days: Set<Int64> = []
    var included: Set<Int64> = []

    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    init(excludes: [(String, Int)], includes: [(String, Int)], format: GanttDateFormat) throws(NativeMermaidError) {
        for (word, line) in excludes {
            let w = word.lowercased()
            if w == "weekends" { weekdays.formUnion([0, 6]); continue }
            if let d = Self.weekdayNames.firstIndex(of: w) { weekdays.insert(d); continue }
            guard let ms = format.parse(word) ?? GanttDateFormat.iso(word) else {
                throw .syntax(line: line, message: "\"\(word)\" isn't weekends, a weekday or a date in \(format.pattern)")
            }
            days.insert(GanttTime.dayNumber(ms))
        }
        for (word, line) in includes {
            guard let ms = format.parse(word) ?? GanttDateFormat.iso(word) else {
                throw .syntax(line: line, message: "\"\(word)\" isn't a date in \(format.pattern)")
            }
            included.insert(GanttTime.dayNumber(ms))
        }
    }

    var isEmpty: Bool { weekdays.isEmpty && days.isEmpty }

    func excludes(_ ms: Int64) -> Bool {
        let d = GanttTime.dayNumber(ms)
        if included.contains(d) { return false }
        return days.contains(d) || weekdays.contains(GanttTime.weekday(d))
    }

    /// Mermaid's rule: walk the task a day at a time from its start, pushing the end out a day for
    /// every excluded day met, so a duration counts working days.
    func extend(start: Int64, end: Int64, line: Int) throws(NativeMermaidError) -> Int64 {
        guard !isEmpty else { return end }
        var day = start, end = end, steps = 0
        while day <= end {
            if excludes(day) { end += GanttTime.day }
            day += GanttTime.day
            steps += 1
            // Excluding every weekday would never end; neither would a centuries-long task be readable.
            if steps > 100_000 { throw .tooLarge }
        }
        return end
    }
}

/// A dayjs-style date format (`YYYY-MM-DD`, `DD/MM/YYYY HH:mm`, …) parsed strictly, as mermaid
/// does, into UTC milliseconds. Fields the format lacks default to 1970-01-01 00:00.
struct GanttDateFormat {
    enum Token: Equatable {
        case literal(String)
        case year4, year2, month2, month1, monthShort, monthLong, day2, day1, hour2, hour1, hour12two, hour12one
        case minute2, minute1, second2, second1, millis, meridiem, unixSeconds, unixMillis
    }

    let pattern: String
    let tokens: [Token]

    private static let table: [(String, Token)] = [
        ("YYYY", .year4), ("YY", .year2), ("MMMM", .monthLong), ("MMM", .monthShort), ("MM", .month2), ("M", .month1),
        ("DD", .day2), ("D", .day1), ("HH", .hour2), ("H", .hour1), ("hh", .hour12two), ("h", .hour12one),
        ("mm", .minute2), ("m", .minute1), ("ss", .second2), ("s", .second1), ("SSS", .millis), ("A", .meridiem),
        ("a", .meridiem), ("X", .unixSeconds), ("x", .unixMillis),
    ]

    init(_ pattern: String) {
        self.pattern = pattern
        var tokens: [Token] = []
        var i = pattern.startIndex
        outer: while i < pattern.endIndex {
            if pattern[i] == "[", let close = pattern[i...].firstIndex(of: "]") {
                tokens.append(.literal(String(pattern[pattern.index(after: i)..<close])))
                i = pattern.index(after: close)
                continue
            }
            for (spelling, token) in Self.table where pattern[i...].hasPrefix(spelling) {
                tokens.append(token)
                i = pattern.index(i, offsetBy: spelling.count)
                continue outer
            }
            tokens.append(.literal(String(pattern[i])))
            i = pattern.index(after: i)
        }
        self.tokens = tokens
    }

    /// The forms JavaScript's `Date` reads, which mermaid falls back to when the format doesn't match.
    static func iso(_ s: String) -> Int64? {
        for f in isoFormats { if let ms = f.parse(s) { return ms } }
        return nil
    }

    private static let isoFormats = ["YYYY-MM-DD", "YYYY-MM-DD[T]HH:mm", "YYYY-MM-DD[T]HH:mm:ss", "YYYY-MM-DD HH:mm", "YYYY-MM-DD HH:mm:ss"]
        .map(GanttDateFormat.init)

    func parse(_ input: String) -> Int64? {
        let s = Array(input.trimmingCharacters(in: .whitespaces))
        var i = 0
        var year: Int64 = 1970, month = 1, day = 1, hour = 0, minute = 0, second = 0, millis = 0
        var pm: Bool?
        var absolute: Int64?
        func digits(_ min: Int, _ max: Int) -> Int64? {
            var n = 0, v: Int64 = 0
            while n < max, i < s.count, let d = s[i].wholeNumberValue, s[i].isASCII {
                v = v * 10 + Int64(d)
                i += 1
                n += 1
            }
            return n >= min ? v : nil
        }
        func word(_ names: [String]) -> Int? {
            for (k, name) in names.enumerated() {
                let a = Array(name)
                if i + a.count <= s.count, String(s[i..<(i + a.count)]).lowercased() == name.lowercased() {
                    i += a.count
                    return k
                }
            }
            return nil
        }
        for token in tokens {
            switch token {
            case let .literal(l):
                let a = Array(l)
                guard i + a.count <= s.count, Array(s[i..<(i + a.count)]) == a else { return nil }
                i += a.count
            case .year4: guard let v = digits(4, 4) else { return nil }; year = v
            case .year2: guard let v = digits(2, 2) else { return nil }; year = v + (v > 68 ? 1900 : 2000)
            case .month2: guard let v = digits(2, 2) else { return nil }; month = Int(v)
            case .month1: guard let v = digits(1, 2) else { return nil }; month = Int(v)
            case .monthShort: guard let k = word(GanttTime.monthsShort) else { return nil }; month = k + 1
            case .monthLong: guard let k = word(GanttTime.monthsLong) else { return nil }; month = k + 1
            case .day2: guard let v = digits(2, 2) else { return nil }; day = Int(v)
            case .day1: guard let v = digits(1, 2) else { return nil }; day = Int(v)
            case .hour2, .hour12two: guard let v = digits(2, 2) else { return nil }; hour = Int(v)
            case .hour1, .hour12one: guard let v = digits(1, 2) else { return nil }; hour = Int(v)
            case .minute2: guard let v = digits(2, 2) else { return nil }; minute = Int(v)
            case .minute1: guard let v = digits(1, 2) else { return nil }; minute = Int(v)
            case .second2: guard let v = digits(2, 2) else { return nil }; second = Int(v)
            case .second1: guard let v = digits(1, 2) else { return nil }; second = Int(v)
            case .millis: guard let v = digits(3, 3) else { return nil }; millis = Int(v)
            case .meridiem: guard let k = word(["am", "pm"]) else { return nil }; pm = k == 1
            case .unixSeconds: guard let v = digits(1, 12) else { return nil }; absolute = v * 1000
            case .unixMillis: guard let v = digits(1, 15) else { return nil }; absolute = v
            }
        }
        guard i == s.count else { return nil }
        if let absolute { return absolute }
        if let pm {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (pm ? 12 : 0)
        }
        guard (1...12).contains(month), (1...GanttTime.daysIn(year, month)).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        return GanttTime.days(year, month, day) * GanttTime.day + Int64(hour) * GanttTime.hour + Int64(minute) * GanttTime.minute
            + Int64(second) * 1000 + Int64(millis)
    }
}

/// Calendar arithmetic on UTC milliseconds since 1970, by Howard Hinnant's civil-date algorithms.
enum GanttTime {
    static let minute: Int64 = 60_000
    static let hour: Int64 = 3_600_000
    static let day: Int64 = 86_400_000

    static let monthsShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let monthsLong = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                             "November", "December"]
    static let weekdaysShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let weekdaysLong = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// Days since 1970-01-01 for a civil date.
    static func days(_ y: Int64, _ m: Int, _ d: Int) -> Int64 {
        let y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = Int64((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1)
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(_ z: Int64) -> (year: Int64, month: Int, day: Int) {
        let z = z + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = Int(doy - (153 * mp + 2) / 5 + 1)
        let m = Int(mp < 10 ? mp + 3 : mp - 9)
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    static func daysIn(_ y: Int64, _ m: Int) -> Int {
        Int(days(m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1, 1) - days(y, m, 1))
    }

    static func dayNumber(_ ms: Int64) -> Int64 { ms >= 0 ? ms / day : (ms - day + 1) / day }

    /// 0 = Sunday.
    static func weekday(_ dayNumber: Int64) -> Int { Int(((dayNumber + 4) % 7 + 7) % 7) }

    /// `ms` moved by whole calendar months, the day clamped to the target month's length.
    static func addMonths(_ ms: Int64, _ n: Int64) -> Int64 {
        let dn = dayNumber(ms), timeOfDay = ms - dn * day
        let c = civil(dn)
        let total = c.year * 12 + Int64(c.month - 1) + n
        let y = total >= 0 ? total / 12 : (total - 11) / 12
        let m = Int(total - y * 12) + 1
        return days(y, m, min(c.day, daysIn(y, m))) * day + timeOfDay
    }

    /// A task length: `3d`, `1.5w`, `12h`, `30m`, `45s`, `500ms`, `2M`, `1y`.
    struct Duration {
        enum Unit: String { case ms, s, m, h, d, w, M, y }
        let amount: Double
        let unit: Unit

        init?(_ s: String) {
            guard let m = s.wholeMatch(of: /([0-9]+(?:\.[0-9]+)?)\s*(ms|s|m|h|d|w|M|y)/), let a = Double(m.output.1),
                  let u = Unit(rawValue: String(m.output.2)) else { return nil }
            amount = a
            unit = u
        }

        func added(to ms: Int64) -> Int64 {
            let fixed: Double
            switch unit {
            case .ms: fixed = 1
            case .s: fixed = 1000
            case .m: fixed = Double(GanttTime.minute)
            case .h: fixed = Double(GanttTime.hour)
            case .d: fixed = Double(GanttTime.day)
            case .w: fixed = Double(GanttTime.day * 7)
            case .M, .y:
                // Whole months and years are calendar steps; fractions fall back to average lengths.
                let months = unit == .M ? amount : amount * 12
                if months == months.rounded(), abs(months) < 1e6 { return GanttTime.addMonths(ms, Int64(months)) }
                fixed = Double(GanttTime.day) * 30.436875 * (unit == .M ? 1 : 12)
            }
            let delta = (amount * fixed).rounded()
            return delta < 1e15 ? ms + Int64(delta) : ms + 1_000_000_000_000_000
        }
    }

    /// An axis step: a fixed number of milliseconds, whole weeks (aligned to Sunday, as d3's
    /// `timeWeek` is), or whole months or years.
    enum Step: Equatable {
        case fixed(Int64)
        case weeks(Int64)
        case months(Int64)

        /// mermaid's `tickInterval`: `1day`, `2week`, `15minute`, `1month`.
        init?(tickInterval s: String) {
            guard let m = s.wholeMatch(of: /([1-9][0-9]{0,5})\s*(millisecond|second|minute|hour|day|week|month)/),
                  let n = Int64(m.output.1) else { return nil }
            switch m.output.2 {
            case "millisecond": self = .fixed(n)
            case "second": self = .fixed(n * 1000)
            case "minute": self = .fixed(n * GanttTime.minute)
            case "hour": self = .fixed(n * GanttTime.hour)
            case "day": self = .fixed(n * GanttTime.day)
            case "week": self = .weeks(n)
            default: self = .months(n)
            }
        }

        /// The step's length for estimating tick counts.
        var approximate: Double {
            switch self {
            case let .fixed(ms): Double(ms)
            case let .weeks(n): Double(n * 7 * GanttTime.day)
            case let .months(n): Double(n) * 30.436875 * Double(GanttTime.day)
            }
        }

        var isSubDay: Bool { if case let .fixed(ms) = self { ms < GanttTime.day } else { false } }

        /// Every aligned step boundary from `lo` to `hi` inclusive.
        func times(from lo: Int64, to hi: Int64) -> [Int64] {
            var out: [Int64] = []
            switch self {
            case let .fixed(ms):
                var t = Self.ceil(lo, ms)
                while t <= hi { out.append(t); t += ms }
            case let .weeks(n):
                // Day 3 since the epoch was a Sunday.
                let period = n * 7 * GanttTime.day
                var t = Self.ceil(lo - 3 * GanttTime.day, period) + 3 * GanttTime.day
                while t <= hi { out.append(t); t += period }
            case let .months(n):
                let c = GanttTime.civil(GanttTime.dayNumber(lo))
                var index = c.year * 12 + Int64(c.month - 1)
                index = (index + n - 1) / n * n
                while true {
                    let y = index >= 0 ? index / 12 : (index - 11) / 12
                    let t = GanttTime.days(y, Int(index - y * 12) + 1, 1) * GanttTime.day
                    if t > hi { break }
                    if t >= lo { out.append(t) }
                    index += n
                }
            }
            return out
        }

        private static func ceil(_ v: Int64, _ step: Int64) -> Int64 {
            let q = v >= 0 ? (v + step - 1) / step : v / step
            return q * step
        }
    }

    static let candidates: [Step] = {
        var c: [Step] = [1, 5, 15, 30].map { .fixed($0 * 1000) } + [1, 5, 15, 30].map { .fixed($0 * minute) }
            + [1, 3, 6, 12].map { .fixed($0 * hour) } + [1, 2].map { .fixed($0 * day) } + [1, 2].map { .weeks($0) }
            + [1, 3, 6].map { .months($0) }
        var years: Int64 = 1
        while years <= 100_000 {
            for k: Int64 in [1, 2, 5] { c.append(.months(12 * years * k)) }
            years *= 10
        }
        return c
    }()

    /// The tick times and label format: the given `tickInterval` if it gives a sane number of
    /// ticks, else the finest step whose labels don't collide across `width`.
    static func ticks(from lo: Int64, to hi: Int64, width: Double, fixed: Step?, format: String?) -> (times: [Int64], format: String) {
        let span = Double(hi - lo)
        func formatFor(_ step: Step) -> String { format ?? (step.isSubDay ? "%H:%M" : "%Y-%m-%d") }
        if let fixed, span / fixed.approximate <= 200 {
            return (fixed.times(from: lo, to: hi), formatFor(fixed))
        }
        for step in candidates where span / step.approximate <= 24 {
            let times = step.times(from: lo, to: hi)
            let f = formatFor(step)
            let widest = times.map { MermaidText.width(GanttTime.format($0, f), size: MermaidText.smallSize) }.max() ?? 0
            let spacing = step.approximate / span * width
            if spacing >= widest + 16 { return (times, f) }
        }
        let last = candidates[candidates.count - 1]
        return (last.times(from: lo, to: hi), formatFor(last))
    }

    /// d3-style strftime: `%Y %y %m %d %e %b %B %a %A %H %I %M %S %L %p %j %%`, with `-` to drop
    /// padding (`%-d`). Unknown directives are kept as written.
    static func format(_ ms: Int64, _ f: String) -> String {
        let dn = dayNumber(ms), timeOfDay = ms - dn * day
        let c = civil(dn)
        let h = Int(timeOfDay / hour), mi = Int(timeOfDay % hour / minute), s = Int(timeOfDay % minute / 1000), l = Int(timeOfDay % 1000)
        var out = ""
        var it = f.makeIterator()
        while let ch = it.next() {
            guard ch == "%" else { out.append(ch); continue }
            guard var d = it.next() else { out.append("%"); break }
            var pad = true
            if d == "-" || d == "_" || d == "0" {
                pad = d == "0"
                guard let next = it.next() else { out += "%\(d)"; break }
                d = next
            }
            func p(_ v: Int, _ w: Int = 2) -> String {
                let s = String(v)
                return pad && s.count < w ? String(repeating: "0", count: w - s.count) + s : s
            }
            switch d {
            case "Y": out += String(c.year)
            case "y": out += p(Int(((c.year % 100) + 100) % 100))
            case "m": out += p(c.month)
            case "d": out += p(c.day)
            case "e": out += String(c.day)
            case "b": out += monthsShort[c.month - 1]
            case "B": out += monthsLong[c.month - 1]
            case "a": out += weekdaysShort[weekday(dn)]
            case "A": out += weekdaysLong[weekday(dn)]
            case "H": out += p(h)
            case "I": out += p(h % 12 == 0 ? 12 : h % 12)
            case "M": out += p(mi)
            case "S": out += p(s)
            case "L": out += p(l, 3)
            case "p": out += h < 12 ? "AM" : "PM"
            case "j": out += p(Int(dn - days(c.year, 1, 1)) + 1, 3)
            case "%": out += "%"
            default: out += "%\(d)"
            }
        }
        return out
    }
}
