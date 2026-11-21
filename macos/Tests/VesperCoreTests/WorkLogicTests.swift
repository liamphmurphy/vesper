import XCTest
@testable import VesperCore

/// A fixed zone so "today" and day labels don't depend on the machine running the tests.
private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
}()

private let locale = Locale(identifier: "en_US")

/// 2026-11-15 14:00 local, as the web tests' `now`.
private let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 14))!

private func isoAt(_ dayOffset: Int, _ hour: Int = 10) -> String {
    let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15 - dayOffset, hour: hour))!
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

private func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) -> T {
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(T.self, from: data)
}

private func mkRun(_ id: String, _ over: [String: Any] = [:]) -> API.Run {
    var json: [String: Any] = [
        "id": id, "ticket_key": "WEB-1", "work_title": "Run \(id)", "purpose": "ticket", "project_key": "WEB",
        "agent": ["id": "a1", "handle": "builder", "name": "Builder", "color_index": 0], "mode": "managed",
        "state": "running", "harness": "claude-code", "model": "opus", "started_at": isoAt(0, 12), "tool_calls": 1,
        "input_tokens": 100, "output_tokens": 50, "cost_usd": 0.25, "plan": [], "scopes": [], "approval_scopes": [],
    ]
    json.merge(over) { $1 }
    return decode(API.Run.self, json)
}

private func mkItem(_ id: String, _ kind: String, _ over: [String: Any] = [:]) -> API.InboxItem {
    var json: [String: Any] = [
        "id": id, "kind": kind, "title": "Item \(id)", "summary": "", "href": "/inbox", "project": "WEB",
        "ticket_key": "WEB-1", "created_at": isoAt(0, 12), "resolved": false, "read": false, "needs_you": true,
    ]
    json.merge(over) { $1 }
    return decode(API.InboxItem.self, json)
}

private func mkTicket(_ key: String, _ over: [String: Any] = [:]) -> API.TicketSummary {
    var json: [String: Any] = [
        "id": key, "key": key, "project_key": "WEB", "title": "Ticket \(key)", "status": "todo", "priority": "medium",
        "labels": [], "unmet_dependencies": 0, "criteria_total": 2, "criteria_done": 1, "updated_at": isoAt(0, 11),
    ]
    json.merge(over) { $1 }
    return decode(API.TicketSummary.self, json)
}

private func runner(online: Bool = true, starting: Bool = false) -> API.RunnerStatus {
    decode(API.RunnerStatus.self, [
        "online": online, "starting": starting, "busy": 2, "queued": 1, "slots": 6, "live": 3, "runners": [],
        "host_folder_workspaces": false,
    ])
}

/// Ported from web/lib/work-overview.test.mjs and lib/run-list.test.mjs (the parts Work uses).
final class WorkLogicTests: XCTestCase {
    func testFilterParsesTheURLAndTheOldDoneHide() {
        XCTAssertEqual(WorkLogic.ActivityFilter(filter: "needs_you", legacyDone: nil), .needsYou)
        XCTAssertEqual(WorkLogic.ActivityFilter(filter: "active", legacyDone: nil), .active)
        XCTAssertEqual(WorkLogic.ActivityFilter(filter: "failed", legacyDone: nil), .failed)
        XCTAssertEqual(WorkLogic.ActivityFilter(filter: nil, legacyDone: "hide"), .active)
        XCTAssertEqual(WorkLogic.ActivityFilter(filter: nil, legacyDone: nil), .all)
        XCTAssertEqual(WorkLogic.ActivityFilter(filter: "unknown", legacyDone: nil), .all)
    }

    func testViewCountsAndFiltersAgree() {
        let runs = [
            mkRun("r-wait", ["state": "waiting", "wait_reason": "approval"]),
            mkRun("r-live"),
            mkRun("r-queue", ["state": "queued"]),
            mkRun("r-fail-today", ["state": "failed", "ended_at": isoAt(0, 9)]),
            mkRun("r-fail-old", ["state": "failed", "started_at": isoAt(2, 9), "ended_at": isoAt(2, 10)]),
            mkRun("r-done", ["state": "completed", "ended_at": isoAt(0, 11), "pr_number": 412]),
            mkRun("r-live"),
        ]
        let needs: Set = ["r-wait"]
        XCTAssertEqual(WorkLogic.viewCounts(runs, needsRunIds: needs, now: now, calendar: calendar),
                       WorkLogic.ViewCounts(all: 6, needsYou: 1, active: 3, failed: 1))
        let six = Array(runs.prefix(6))
        XCTAssertEqual(WorkLogic.filterRuns(six, .needsYou, needsRunIds: needs, now: now, calendar: calendar).map(\.id), ["r-wait"])
        XCTAssertEqual(WorkLogic.filterRuns(six, .active, needsRunIds: needs, now: now, calendar: calendar).map(\.id),
                       ["r-wait", "r-live", "r-queue"])
        XCTAssertEqual(WorkLogic.filterRuns(six, .failed, needsRunIds: needs, now: now, calendar: calendar).map(\.id), ["r-fail-today"])
        XCTAssertEqual(WorkLogic.filterRuns(six, .all, needsRunIds: needs, now: now, calendar: calendar).count, 6)
    }

    func testDelegationWaitsDontNeedYou() {
        XCTAssertFalse(WorkLogic.isRunNeedsYou(mkRun("d", ["state": "waiting", "wait_reason": "delegation"]), needsRunIds: []))
        XCTAssertTrue(WorkLogic.isRunNeedsYou(mkRun("d", ["state": "running"]), needsRunIds: ["d"]))
    }

    func testSidebarGroupsActiveFirstThenDaysAndCompactTimes() {
        let runs = [
            mkRun("r-wait", ["state": "waiting", "wait_reason": "human_reply"]),
            mkRun("r-live"),
            mkRun("r-today", ["state": "completed", "ended_at": isoAt(0, 12)]),
            mkRun("r-yest", ["state": "completed", "ended_at": isoAt(1, 15)]),
            mkRun("r-week", ["state": "completed", "ended_at": isoAt(3, 15)]),
            mkRun("r-old", ["state": "cancelled", "ended_at": isoAt(20, 15)]),
        ]
        let groups = WorkLogic.groupSidebarRuns(runs, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(groups.map(\.label), ["Active", "Earlier today", "Yesterday", "Thursday", "Oct 26"])
        XCTAssertEqual(groups.map(\.kind), [.active, .history, .history, .history, .history])
        XCTAssertEqual(groups[0].runs.map(\.id), ["r-wait", "r-live"])
        XCTAssertEqual(WorkLogic.compactRunTime(runs[0], dot: .human, now: now), "wait")
        XCTAssertEqual(WorkLogic.compactRunTime(runs[1], dot: .running, now: now), "live")
        XCTAssertEqual(WorkLogic.compactRunTime(mkRun("q", ["state": "queued"]), dot: .queued, now: now), "queue")
        XCTAssertEqual(WorkLogic.compactRunTime(runs[2], dot: .done, now: now), "2h")
        XCTAssertEqual(WorkLogic.compactRunTime(runs[3], dot: .done, now: now), "23h")
        XCTAssertEqual(WorkLogic.compactRunTime(runs[4], dot: .done, now: now), "3d")
    }

    func testDayLabelAddsTheYearOnlyForOtherYears() {
        XCTAssertEqual(WorkLogic.dayLabel("2025-12-30T18:00:00Z", now: now, calendar: calendar, locale: locale), "Dec 30, 2025")
    }

    func testRunDotTitleAndSearch() {
        XCTAssertEqual(WorkLogic.runDot(mkRun("a", ["state": "waiting", "wait_reason": "approval"])), .human)
        XCTAssertEqual(WorkLogic.runDot(mkRun("a", ["state": "waiting", "wait_reason": "delegation"])), .running)
        XCTAssertEqual(WorkLogic.runDot(mkRun("a", ["state": "paused"])), .human)
        XCTAssertEqual(WorkLogic.runDot(mkRun("a", ["state": "blocked"])), .failed)
        XCTAssertEqual(WorkLogic.runDot(mkRun("a", ["state": "completed"])), .done)
        XCTAssertEqual(WorkLogic.runDot(mkRun("a", ["state": "cancelled"])), .idle)
        XCTAssertEqual(WorkLogic.runDot(mkRun("a", ["state": "queued"])), .queued)
        XCTAssertEqual(WorkLogic.runDot(mkRun("a"), needsYou: true), .human)
        XCTAssertEqual(WorkLogic.runTitle(mkRun("a", ["work_title": "", "ticket_key": ""])), "Ticket run")
        XCTAssertEqual(WorkLogic.runTitle(mkRun("a", ["work_title": "", "ticket_key": "WEB-9"])), "WEB-9")
        XCTAssertTrue(WorkLogic.matchesRun(mkRun("a"), "  BUILD "))
        XCTAssertTrue(WorkLogic.matchesRun(mkRun("a"), "ticket run"))
        XCTAssertFalse(WorkLogic.matchesRun(mkRun("a"), "nope"))
        XCTAssertTrue(WorkLogic.matchesItem(mkItem("i", "approval", ["title": "Ship the thing"]), "ship"))
    }

    func testStatsDerivePassRatePRsAndNeedsBreakdown() {
        let runs = [
            mkRun("c1", ["state": "completed", "started_at": isoAt(0, 8), "ended_at": isoAt(0, 9), "pr_number": 410]),
            mkRun("c2", ["state": "completed", "started_at": isoAt(0, 10), "ended_at": isoAt(0, 11), "pr_number": 410]),
            mkRun("c3", ["state": "completed", "started_at": isoAt(0, 11), "ended_at": isoAt(0, 12), "pr_number": 411]),
            mkRun("f1", ["state": "failed", "started_at": isoAt(0, 7), "ended_at": isoAt(0, 8)]),
            mkRun("old", ["state": "failed", "started_at": isoAt(3, 7), "ended_at": isoAt(3, 8)]),
        ]
        let inbox = [
            mkItem("a1", "approval"), mkItem("q1", "question"), mkItem("r1", "review"),
            mkItem("ignored", "review", ["read": true]),
        ]
        let stats = WorkLogic.activityStats(runs: runs, inbox: inbox, runner: runner(), now: now, calendar: calendar)
        XCTAssertEqual(stats.slotsBusy, 2)
        XCTAssertEqual(stats.slotsMax, 6)
        XCTAssertEqual(stats.queued, 1)
        XCTAssertEqual(stats.needsYouCount, 3)
        XCTAssertEqual(stats.needsBreakdown, "1 approval · 1 question · 1 review")
        XCTAssertEqual(stats.completedToday, 3)
        XCTAssertEqual(stats.prsToday, 2)
        XCTAssertEqual(stats.passRatePct, 75)
        XCTAssertEqual(stats.todayDetail, "2 PRs · 75% pass")
        XCTAssertEqual(stats.runnerState, "online")

        let starting = WorkLogic.activityStats(runs: runs, inbox: inbox, runner: runner(online: false, starting: true), now: now, calendar: calendar)
        XCTAssertEqual(starting.runnerState, "starting")
        let empty = WorkLogic.activityStats(runs: [], inbox: [], runner: nil, now: now, calendar: calendar)
        XCTAssertEqual(empty.runnerState, "offline")
        XCTAssertNil(empty.passRatePct)
        XCTAssertEqual(empty.needsBreakdown, "Queue clear")
        XCTAssertEqual(empty.todayDetail, "0 PRs")
    }

    func testOverviewSections() {
        let assignee: [String: Any] = ["id": "a1", "name": "Builder", "handle": "builder", "color_index": 0]
        let runs = [
            mkRun("live", ["ticket_key": "WEB-2"]), mkRun("live"),
            mkRun("done", ["state": "completed", "ended_at": isoAt(0, 11)]),
            mkRun("yest", ["state": "completed", "ended_at": isoAt(1, 11)]),
        ]
        let running = WorkLogic.runningNow(runs)
        XCTAssertEqual(running.map(\.id), ["live"])
        XCTAssertEqual(WorkLogic.finishedToday(runs, now: now, calendar: calendar).map(\.id), ["done"])
        let tickets = [
            mkTicket("WEB-1", ["assignee": assignee]),
            mkTicket("WEB-2", ["assignee": assignee]),
            mkTicket("WEB-3", ["unmet_dependencies": 1, "assignee": assignee]),
            mkTicket("WEB-4"),
            mkTicket("WEB-5", ["status": "in_progress", "assignee": assignee]),
        ]
        XCTAssertEqual(WorkLogic.readyTickets(tickets, running: running).map(\.key), ["WEB-1", "WEB-4"])
        XCTAssertEqual(WorkLogic.assignedReadyKeys(tickets, running: running), ["WEB-1"])
    }

    func testPlanStepAndProgress() {
        let plan: [[String: Any]] = [
            ["position": 1, "text": "Read", "state": "done"],
            ["position": 2, "text": "Write the tests", "state": "current"],
            ["position": 3, "text": "Ship", "state": "pending"],
        ]
        let run = mkRun("p", ["plan": plan])
        XCTAssertEqual(WorkLogic.currentStep(run), "Step 2/3 · Write the tests")
        XCTAssertEqual(WorkLogic.planProgress(run), 33)
        XCTAssertNil(WorkLogic.planProgress(mkRun("none")))
        XCTAssertEqual(WorkLogic.planProgress(mkRun("z", ["plan": [["position": 1, "text": "x", "state": "pending"]]])), 8)
    }

    func testNeedsFollowTheTrayOrderAndFilters() {
        let items = [
            mkItem("m", "mention", ["created_at": isoAt(0, 9)]),
            mkItem("q", "question", ["created_at": isoAt(0, 8)]),
            mkItem("a2", "approval", ["created_at": isoAt(0, 11)]),
            mkItem("a1", "approval", ["created_at": isoAt(0, 10)]),
            mkItem("done", "approval", ["read": true]),
            mkItem("fyi", "merged", ["needs_you": false]),
            mkItem("other", "approval", ["project": "OPS"]),
            mkItem("ada", "approval", ["agent": ["id": "x", "handle": "ada", "name": "Ada", "color_index": 1]]),
        ]
        XCTAssertEqual(WorkLogic.needs(items, project: "WEB", agent: nil).map(\.id), ["a1", "a2", "ada", "q", "m"])
        XCTAssertEqual(WorkLogic.needs(items, project: nil, agent: "ada").map(\.id), ["ada"])
        XCTAssertEqual(WorkLogic.needs(items, project: "", agent: "").count, 6)
        XCTAssertEqual(WorkLogic.itemHref(mkItem("r", "approval", ["run_id": "r9"])), "/runs/r9")
        XCTAssertEqual(WorkLogic.itemHref(mkItem("r", "mention", ["href": "/tickets/WEB-1"])), "/tickets/WEB-1")
    }

    func testActivityListsKeepRunlessNeedsAndCountThem() {
        let runs = [mkRun("r1", ["state": "waiting", "wait_reason": "approval"]), mkRun("r2", ["work_title": "Other"])]
        let needs = [mkItem("n1", "approval", ["run_id": "r1"]), mkItem("n2", "mention"), mkItem("n3", "question", ["run_id": "gone"])]
        let lists = WorkLogic.activityLists(runs: runs, shownNeeds: needs, search: "", filter: .all, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(lists.needsRunIds, ["r1", "gone"])
        XCTAssertEqual(lists.nonRunNeeds.map(\.id), ["n2", "n3"])
        XCTAssertEqual(lists.counts.needsYou, 3)
        XCTAssertEqual(lists.groups.map(\.label), ["Active"])
        let failed = WorkLogic.activityLists(runs: runs, shownNeeds: needs, search: "other", filter: .failed, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(failed.nonRunNeeds.isEmpty)
        XCTAssertEqual(failed.counts.all, 1)
        XCTAssertTrue(failed.groups.isEmpty)
    }

    func testFormatting() {
        XCTAssertEqual(WorkLogic.usd(micros: 18_420_000), "$18.42")
        XCTAssertEqual(WorkLogic.usd(micros: 1_234_500_000), "$1,234.50")
        XCTAssertEqual(WorkLogic.usd(micros: 4_000), "$0.004")
        XCTAssertEqual(WorkLogic.usd(micros: 400), "< $0.001")
        XCTAssertEqual(WorkLogic.usd(micros: 0), "$0.00")
        XCTAssertEqual(WorkLogic.spendLabel(micros: 18_420_000, unpricedRuns: 1), "≥ $18.42")
        XCTAssertEqual(WorkLogic.spendLabel(micros: 0, unpricedRuns: 2), "Unknown")
        XCTAssertEqual(WorkLogic.runCost(1.5, source: "reported"), "$1.50")
        XCTAssertEqual(WorkLogic.runCost(1.5, source: "computed"), "~$1.50")
        XCTAssertEqual(WorkLogic.runCost(1.5, source: "partial"), "≥ $1.50 (partial)")
        XCTAssertEqual(WorkLogic.runCost(1.5, source: nil), "Unknown")
        XCTAssertEqual(WorkLogic.shortAgo("2026-11-15T21:31:00Z", now: now, calendar: calendar, locale: locale), "29m")
        XCTAssertEqual(WorkLogic.shortAgo("2026-11-15T21:59:30Z", now: now, calendar: calendar, locale: locale), "now")
        XCTAssertEqual(WorkLogic.shortAgo(isoAt(0, 9), now: now, calendar: calendar, locale: locale), "5h")
        XCTAssertEqual(WorkLogic.shortAgo(isoAt(2, 9), now: now, calendar: calendar, locale: locale), "Fri")
        XCTAssertEqual(WorkLogic.shortAgo(isoAt(9, 9), now: now, calendar: calendar, locale: locale), "Nov 6")
        let range = WorkLogic.presetRange(days: 7, now: ISO8601DateFormatter().date(from: "2026-11-15T03:00:00Z")!)
        XCTAssertEqual(range.from, "2026-11-09")
        XCTAssertEqual(range.to, "2026-11-15")
    }

    func testStatusLineAndLinks() {
        let costs = decode(API.CostReport.self, [
            "total": ["key": "total", "label": "Total", "runs": 5, "tokens": 1000, "cost_micros": 18_420_000, "unpriced_runs": 0],
            "unpriced_runs": 0, "estimated": ["tickets": 0, "points": 0, "cost_micros": 0], "days": [], "agents": [],
            "projects": [], "models": [], "purposes": [], "top_tickets": [],
        ])
        XCTAssertEqual(WorkLogic.statusText(runner: runner(), costs: costs), "2 busy · 6 slots · $18.42 7d")
        XCTAssertEqual(WorkLogic.statusText(runner: runner(online: false, starting: true), costs: nil), "Runner starting")
        XCTAssertEqual(WorkLogic.statusText(runner: runner(online: false), costs: nil), "Runner offline")
        XCTAssertEqual(WorkLogic.statusText(runner: nil, costs: nil), "")
        XCTAssertEqual(WorkLogic.reportsHref(project: "WEB"), "/reports?tab=costs&range=7&project=WEB")
        XCTAssertEqual(WorkLogic.reportsHref(project: nil), "/reports?tab=costs&range=7")
        XCTAssertEqual(WorkLogic.tasksHref(project: "A B"), "/tickets?project=A%20B")
        XCTAssertEqual(WorkLogic.newTicketHref(project: ""), "/tickets/new")
    }

    /// web work-screen.tsx's and legacy-work.tsx's redirects.
    func testOldWorkLinksRedirect() {
        XCTAssertNil(WorkLogic.redirect(query: [:]))
        XCTAssertNil(WorkLogic.redirect(query: ["project": "WEB", "filter": "failed"]))
        XCTAssertEqual(WorkLogic.redirect(query: ["run": "r1"]), "/runs/r1")
        XCTAssertEqual(WorkLogic.redirect(query: ["view": "tickets", "ticket": "WEB-1"]), "/tickets/WEB-1")
        XCTAssertEqual(WorkLogic.redirect(query: ["view": "tickets", "project": "WEB"]), "/tickets?project=WEB")
        XCTAssertEqual(WorkLogic.redirect(query: ["view": "tickets", "layout": "board", "project": "WEB"]), "/tickets?layout=board&project=WEB")
        XCTAssertEqual(WorkLogic.redirect(query: ["view": "epics", "epic": "e1"]), "/epics/e1")
        XCTAssertEqual(WorkLogic.redirect(query: ["view": "epics"]), "/tickets?layout=epics")
        XCTAssertEqual(WorkLogic.redirect(query: ["layout": "epics", "project": "WEB"]), "/tickets?layout=epics&project=WEB")
    }

    func testKindRankFollowsTheInboxGroups() {
        XCTAssertEqual(InboxLogic.kindRank("approval"), 0)
        XCTAssertEqual(InboxLogic.kindRank("secret_approval"), 0)
        XCTAssertLessThan(InboxLogic.kindRank("question"), InboxLogic.kindRank("mention"))
        XCTAssertEqual(InboxLogic.kindRank("unknown"), InboxLogic.groups.count)
    }
}
