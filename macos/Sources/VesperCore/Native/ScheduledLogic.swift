import Foundation

/// Pure domain logic for Scheduled tasks: filtering, human-readable schedule & cron descriptions,
/// form draft & validation, and `NavModel` builder (Foundation only; zero AppKit).
/// Ports `web/lib/schedule-ui.ts` and `web/lib/native-shell/models/scheduled.ts`.
public enum ScheduledLogic {
    // MARK: - Filter & Counts

    public enum Filter: String, Sendable, CaseIterable, Equatable {
        case all
        case active
        case paused

        public var label: String {
            switch self {
            case .all: "All"
            case .active: "Active"
            case .paused: "Paused"
            }
        }
    }

    public struct Counts: Sendable, Equatable {
        public var all: Int
        public var active: Int
        public var paused: Int

        public init(all: Int = 0, active: Int = 0, paused: Int = 0) {
            self.all = all; self.active = active; self.paused = paused
        }

        public subscript(_ filter: Filter) -> Int {
            switch filter {
            case .all: all
            case .active: active
            case .paused: paused
            }
        }
    }

    public static func counts(_ tasks: [API.ScheduledTask]) -> Counts {
        let active = tasks.filter(\.enabled).count
        return Counts(all: tasks.count, active: active, paused: tasks.count - active)
    }

    public static func filter(_ tasks: [API.ScheduledTask], by filter: Filter) -> [API.ScheduledTask] {
        switch filter {
        case .all: tasks
        case .active: tasks.filter(\.enabled)
        case .paused: tasks.filter { !$0.enabled }
        }
    }

    /// Count of tasks whose latest run is waiting on the person.
    public static func tasksNeedingYou(_ tasks: [API.ScheduledTask]) -> Int {
        tasks.filter { $0.runs.first?.state == .waiting }.count
    }

    // MARK: - Formatting & Schedule Descriptions

    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    public static let weekdayButtons: [(day: Int, letter: String, full: String)] = [
        (1, "M", "Monday"),
        (2, "T", "Tuesday"),
        (3, "W", "Wednesday"),
        (4, "T", "Thursday"),
        (5, "F", "Friday"),
        (6, "S", "Saturday"),
        (0, "S", "Sunday"),
    ]

    public static func clockLabel(_ atTime: String) -> String {
        let parts = atTime.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else {
            return atTime
        }
        let hour12 = h % 12 == 0 ? 12 : h % 12
        let period = h < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", hour12, m, period)
    }

    public static func ordinal(_ n: Int) -> String {
        let mod100 = abs(n) % 100
        let suffix: String
        if (11...13).contains(mod100) {
            suffix = "th"
        } else {
            switch abs(n) % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }

    public static func describeSchedule(
        frequency: API.ScheduledTask.Frequency,
        weekdays: [Int],
        monthDay: Int,
        atTime: String,
        cron: String
    ) -> String {
        let at = clockLabel(atTime)
        switch frequency {
        case .daily:
            return "Every day at \(at)"
        case .weekly:
            let days = Array(Set(weekdays)).sorted()
            if days == [1, 2, 3, 4, 5] { return "Weekdays at \(at)" }
            if days.count == 7 { return "Every day at \(at)" }
            let labels = days.compactMap { (0..<dayNames.count).contains($0) ? dayNames[$0] : nil }
            if labels.isEmpty { return "Weekly at \(at)" }
            return "Every \(labels.joined(separator: ", ")) at \(at)"
        case .monthly:
            return "\(ordinal(monthDay)) of the month at \(at)"
        default:
            let trimmed = cron.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Cron" : "Cron: \(trimmed)"
        }
    }

    public static func describeSchedule(_ task: API.ScheduledTask) -> String {
        describeSchedule(
            frequency: task.frequency,
            weekdays: task.weekdays,
            monthDay: task.monthDay,
            atTime: task.atTime,
            cron: task.cron
        )
    }

    public static func moneyLabel(micros: Int) -> String {
        String(format: "$%.2f", Double(micros) / 1_000_000.0)
    }

    public static func runStateLabel(_ state: API.ScheduledRun.State) -> String {
        switch state {
        case .running: "Running"
        case .waiting: "Needs you"
        case .done: "Done"
        case .failed: "Failed"
        default: state.rawValue.capitalized
        }
    }

    public static func runStateTone(_ state: API.ScheduledRun.State) -> String {
        switch state {
        case .running: "neutral"
        case .waiting: "human"
        case .done: "done"
        case .failed: "blocked"
        default: "neutral"
        }
    }

    // MARK: - Cron Validation & Helpers

    public struct CronValidation: Sendable, Equatable {
        public var isValid: Bool
        public var summary: String

        public init(isValid: Bool, summary: String) {
            self.isValid = isValid; self.summary = summary
        }
    }

    /// Validates a standard 5-field cron expression (`minute hour dom month dow`) and returns
    /// either a short description or a validation error.
    public static func validateCron(_ expression: String) -> CronValidation {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CronValidation(isValid: false, summary: "Enter a 5-field cron expression (e.g. 0 9 * * 1-5).")
        }
        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else {
            return CronValidation(isValid: false, summary: "Expected 5 fields (minute hour day month weekday), got \(fields.count).")
        }
        let bounds: [(String, ClosedRange<Int>)] = [
            ("minute", 0...59),
            ("hour", 0...23),
            ("day of month", 1...31),
            ("month", 1...12),
            ("day of week", 0...7),
        ]
        for (field, (name, range)) in zip(fields, bounds) {
            if !isValidCronField(field, range: range) {
                return CronValidation(isValid: false, summary: "Invalid \(name) field: “\(field)”.")
            }
        }
        return CronValidation(isValid: true, summary: describeCron(fields: fields))
    }

    private static func isValidCronField(_ field: String, range: ClosedRange<Int>) -> Bool {
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let token = String(part)
            guard !token.isEmpty else { return false }
            let stepParts = token.split(separator: "/", omittingEmptySubsequences: false)
            guard stepParts.count <= 2 else { return false }
            if stepParts.count == 2 {
                guard let step = Int(stepParts[1]), step > 0 else { return false }
            }
            let base = String(stepParts[0])
            if base == "*" { continue }
            let rangeParts = base.split(separator: "-", omittingEmptySubsequences: false)
            if rangeParts.count == 1 {
                guard let v = Int(rangeParts[0]), range.contains(v) else { return false }
            } else if rangeParts.count == 2 {
                guard let lo = Int(rangeParts[0]), let hi = Int(rangeParts[1]),
                      range.contains(lo), range.contains(hi), lo <= hi else { return false }
            } else {
                return false
            }
        }
        return true
    }

    private static func describeCron(fields: [String]) -> String {
        let (min, hour, dom, mon, dow) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        if let m = Int(min), let h = Int(hour), dom == "*", mon == "*" {
            let at = clockLabel(String(format: "%02d:%02d", h, m))
            if dow == "*" { return "Every day at \(at)" }
            if dow == "1-5" { return "Weekdays at \(at)" }
            if dow == "0,6" || dow == "6,0" { return "Weekends at \(at)" }
            return "At \(at) on weekday \(dow)"
        }
        if min.hasPrefix("*/"), let step = Int(min.dropFirst(2)), hour == "*", dom == "*", mon == "*", dow == "*" {
            return "Every \(step) minutes"
        }
        if min == "0", hour.hasPrefix("*/"), let step = Int(hour.dropFirst(2)), dom == "*", mon == "*", dow == "*" {
            return "Every \(step) hours"
        }
        return "Cron: \(fields.joined(separator: " "))"
    }

    // MARK: - Form Draft & Validation

    public struct TaskDraft: Sendable, Equatable {
        public var revision: Int?
        public var name: String
        public var kind: API.ScheduledTaskInput.Kind
        public var instructions: String
        public var workflowId: String?
        public var personaId: String?
        public var project: String?
        public var connectorIds: [String]
        public var customAppSlug: String?
        public var customAppTool: String?
        public var customAppArgsText: String
        public var frequency: API.ScheduledTaskInput.Frequency
        public var weekdays: [Int]
        public var monthDay: Int
        public var atTime: String
        public var timezone: String
        public var cron: String
        public var enabled: Bool
        public var maxMinutes: Int
        public var maxCostMicros: Int

        public static func blank(timezone: String = TimeZone.current.identifier) -> TaskDraft {
            TaskDraft(
                revision: nil,
                name: "",
                kind: .prompt,
                instructions: "",
                workflowId: nil,
                personaId: nil,
                project: nil,
                connectorIds: [],
                customAppSlug: nil,
                customAppTool: nil,
                customAppArgsText: "",
                frequency: .weekly,
                weekdays: [1],
                monthDay: 1,
                atTime: "08:00",
                timezone: timezone,
                cron: "",
                enabled: true,
                maxMinutes: 15,
                maxCostMicros: 1_000_000
            )
        }

        public static func from(_ task: API.ScheduledTask) -> TaskDraft {
            let argsText: String
            if let args = task.customAppArgs, !args.isEmpty,
               let data = try? JSONEncoder().encode(args),
               let str = String(data: data, encoding: .utf8) {
                argsText = str
            } else {
                argsText = ""
            }
            return TaskDraft(
                revision: task.revision,
                name: task.name,
                kind: API.ScheduledTaskInput.Kind(rawValue: task.kind.rawValue),
                instructions: task.instructions,
                workflowId: task.workflowId,
                personaId: task.personaId,
                project: task.project,
                connectorIds: task.connectorIds,
                customAppSlug: task.customAppSlug,
                customAppTool: task.customAppTool,
                customAppArgsText: argsText,
                frequency: API.ScheduledTaskInput.Frequency(rawValue: task.frequency.rawValue),
                weekdays: task.weekdays,
                monthDay: task.monthDay,
                atTime: task.atTime,
                timezone: task.timezone,
                cron: task.cron,
                enabled: task.enabled,
                maxMinutes: task.maxMinutes,
                maxCostMicros: task.maxCostMicros
            )
        }

        public func toInput(parsedArgs: [String: JSONValue]? = nil) -> API.ScheduledTaskInput {
            API.ScheduledTaskInput(
                atTime: atTime,
                connectorIds: connectorIds,
                cron: cron,
                customAppArgs: kind == .customApp ? (parsedArgs ?? [:]) : nil,
                customAppSlug: kind == .customApp ? customAppSlug : nil,
                customAppTool: kind == .customApp ? customAppTool : nil,
                enabled: enabled,
                frequency: frequency,
                instructions: instructions,
                kind: kind,
                maxCostMicros: maxCostMicros,
                maxMinutes: maxMinutes,
                monthDay: monthDay,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                personaId: kind == .customApp ? nil : personaId,
                project: kind == .customApp ? nil : project,
                revision: revision,
                timezone: timezone.trimmingCharacters(in: .whitespacesAndNewlines),
                weekdays: weekdays,
                workflowId: kind == .workflow ? workflowId : nil
            )
        }
    }

    public struct ValidationResult: Sendable, Equatable {
        public var isValid: Bool
        public var errors: [String]
        public var parsedArgs: [String: JSONValue]?

        public init(isValid: Bool, errors: [String], parsedArgs: [String: JSONValue]? = nil) {
            self.isValid = isValid; self.errors = errors; self.parsedArgs = parsedArgs
        }
    }

    public static func validate(_ draft: TaskDraft) -> ValidationResult {
        var errors: [String] = []
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Name is required.")
        }
        var parsedArgs: [String: JSONValue]? = nil
        switch draft.kind {
        case .workflow:
            if (draft.workflowId ?? "").isEmpty {
                errors.append("Choose a published workflow.")
            }
        case .customApp:
            if (draft.customAppSlug ?? "").isEmpty || (draft.customAppTool ?? "").isEmpty {
                errors.append("Choose a Custom App and tool.")
            }
            let trimmed = draft.customAppArgsText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard let data = trimmed.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    errors.append("Enter valid JSON for arguments.")
                    break
                }
                if case .object(let obj) = decoded {
                    parsedArgs = obj
                } else {
                    errors.append("Arguments must be a JSON object.")
                }
            }
        default:
            break
        }
        if draft.frequency == .weekly && draft.weekdays.isEmpty {
            errors.append("Pick at least one weekday.")
        }
        if draft.frequency == .monthly && !(1...31).contains(draft.monthDay) {
            errors.append("Day of month must be between 1 and 31.")
        }
        if draft.frequency == .cron {
            let cronCheck = validateCron(draft.cron)
            if !cronCheck.isValid { errors.append(cronCheck.summary) }
        }
        if draft.timezone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Time zone is required.")
        }
        if !(1...240).contains(draft.maxMinutes) {
            errors.append("Time limit must be between 1 and 240 minutes.")
        }
        if draft.kind != .customApp && draft.maxCostMicros < 10_000 {
            errors.append("Cost limit must be at least $0.01.")
        }
        return ValidationResult(isValid: errors.isEmpty, errors: errors, parsedArgs: parsedArgs)
    }

    // MARK: - NavModel Builder

    public static let navId = "scheduled"
    public static let newActionId = "new-task"
    public static let filterPickerId = "filter"

    public static func navModel(
        tasks: [API.ScheduledTask],
        filter selectedFilter: Filter,
        selectedId: String?
    ) -> NavModel {
        let c = counts(tasks)
        let rows = filter(tasks, by: selectedFilter)
        return NavModel(
            id: navId,
            title: "Scheduled",
            actions: [NavAction(id: newActionId, label: "Create scheduled task", icon: "plus", accent: true)],
            picker: NavPicker(id: filterPickerId, value: selectedFilter.rawValue, options: [
                NavPickerOption(value: Filter.all.rawValue, label: "All \(c.all)"),
                NavPickerOption(value: Filter.active.rawValue, label: "Active \(c.active)"),
                NavPickerOption(value: Filter.paused.rawValue, label: "Paused \(c.paused)"),
            ]),
            sections: [
                NavSection(
                    id: "tasks",
                    items: rows.map { task in
                        NavItem(
                            id: task.id,
                            title: task.name,
                            subtitle: describeSchedule(task),
                            status: task.enabled ? .done : nil
                        )
                    },
                    emptyText: tasks.isEmpty ? "No scheduled tasks yet" : "Nothing matches this filter."
                ),
            ],
            selectedId: selectedId == "new" ? nil : selectedId
        )
    }

    public enum NavActionResult: Sendable, Equatable {
        case newTask
        case selectTask(String)
        case filter(Filter)
    }

    public static func navAction(for command: NativeCommand) -> NavActionResult? {
        switch command {
        case .navAction(navId, newActionId, _, _):
            return .newTask
        case .navActivate(navId, let itemId, _):
            return .selectTask(itemId)
        case .navPicker(navId, filterPickerId, let value):
            return Filter(rawValue: value).map(NavActionResult.filter)
        default:
            return nil
        }
    }
}
