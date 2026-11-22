import XCTest
@testable import VesperCore

final class RailLogicTests: XCTestCase {
    private func samplePR(
        id: String = "o/r#7",
        number: Int = 7,
        title: String = "Fix the thing",
        repository: String = "o/r",
        direct: Bool = true,
        team: Bool = false,
        updatedAt: String = "2026-11-20T12:00:00Z",
        url: String = "https://github.com/o/r/pull/7"
    ) -> API.GitHubReviewRequest {
        API.GitHubReviewRequest(
            additions: 10,
            authorLogin: "alice",
            createdAt: "2026-11-20T10:00:00Z",
            deletions: 2,
            direct: direct,
            draft: false,
            id: id,
            number: number,
            repository: repository,
            team: team,
            title: title,
            updatedAt: updatedAt,
            url: url
        )
    }

    private func sampleHarness(
        harness: String,
        label: String,
        connected: Bool = true,
        running: Int = 0,
        limitedUntil: String? = nil,
        usageAvailable: Bool = true,
        usageCheckedAt: String? = "2026-11-22T06:59:20Z",
        usageChecking: Bool = false,
        windows: [API.UsageWindow] = []
    ) -> API.HarnessActivity {
        API.HarnessActivity(
            connected: connected,
            harness: harness,
            label: label,
            limitedUntil: limitedUntil,
            running: running,
            usageAvailable: usageAvailable,
            usageCheckedAt: usageCheckedAt,
            usageChecking: usageChecking,
            windows: windows
        )
    }

    func testDockItemsFromInspectorModel() {
        let model = InspectorModel(
            id: "run",
            open: true,
            activeTabId: "chat",
            tabs: [
                InspectorTab(id: "context", label: "Context", icon: "sidebar", kind: .native),
                InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .companion, busy: true, unread: true),
            ]
        )

        let openItems = RailLogic.dockItems(from: model)
        XCTAssertEqual(openItems.map(\.id), ["dock.tab:context", "dock.tab:chat"])
        XCTAssertEqual(openItems.map(\.active), [false, true])
        XCTAssertEqual(openItems[1].label, "Chat (working)")
        XCTAssertEqual(openItems[1].badge, AreaBadge(tone: .human))
        XCTAssertEqual(openItems[1].status, .accent)

        var closed = model
        closed.open = false
        let closedItems = RailLogic.dockItems(from: closed)
        XCTAssertTrue(closedItems.allSatisfy { $0.active == false })

        // Popped-out inspector keeps its active tab highlighted in the rail.
        let poppedItems = RailLogic.dockItems(from: closed, poppedOut: true)
        XCTAssertEqual(poppedItems.map(\.active), [false, true])

        XCTAssertEqual(RailLogic.dockItems(from: nil), [])
    }

    func testEffectiveRailTopPrefersInspectorForNativeAndPageTopForWeb() {
        let companion = InspectorLogic.defaultCompanion(open: false, path: "/chat")
        let webTop = [RailItem(id: "dock.tab:playground", label: "Start playground", icon: "playLeft")]

        // Native screens always use their inspector's tabs, ignoring any stale page rail.
        let nativeTop = RailLogic.effectiveRailTop(nativeActive: true, inspector: companion, pageRailTop: webTop)
        XCTAssertEqual(nativeTop.map(\.id), ["dock.tab:chat"])

        // Web screens keep their own top rail items (including action buttons).
        let webResult = RailLogic.effectiveRailTop(nativeActive: false, inspector: companion, pageRailTop: webTop)
        XCTAssertEqual(webResult.map(\.id), ["dock.tab:playground"])

        // Web screens with no page rail fall back to inspector tabs.
        let webFallback = RailLogic.effectiveRailTop(nativeActive: false, inspector: companion, pageRailTop: nil)
        XCTAssertEqual(webFallback.map(\.id), ["dock.tab:chat"])
    }

    func testReviewFilteringDismissalAndRestore() {
        let directPR = samplePR(id: "o/r#1", number: 1, direct: true, team: false, updatedAt: "2026-11-20T12:00:00Z")
        let teamPR = samplePR(id: "o/r#2", number: 2, direct: false, team: true, updatedAt: "2026-11-20T13:00:00Z")
        let response = API.GitHubReviewRequestsResponse(
            configured: true,
            items: [directPR, teamPR],
            syncedAt: "2026-11-20T14:00:00Z"
        )

        // Direct-only filter
        let directOnly = RailLogic.buildReviewInput(
            response: response,
            dismissed: [:],
            prefs: RailLogic.ReviewFilterPrefs(direct: true, team: false),
            approved: 0
        )
        XCTAssertEqual(directOnly.requests.map(\.id), ["o/r#1"])
        XCTAssertEqual(directOnly.counts, RailLogic.ReviewCounts(direct: 1, team: 1))
        XCTAssertEqual(directOnly.dismissed, 0)

        // Dismiss directPR -> hidden while updatedAt matches
        let dismissed = RailLogic.dismiss([directPR], in: [:])
        let afterDismiss = RailLogic.buildReviewInput(
            response: response,
            dismissed: dismissed,
            prefs: RailLogic.ReviewFilterPrefs(direct: true, team: false),
            approved: 0
        )
        XCTAssertTrue(afterDismiss.requests.isEmpty)
        XCTAssertEqual(afterDismiss.dismissed, 1)

        // Reappears when PR is updated on GitHub
        var updatedDirect = directPR
        updatedDirect.updatedAt = "2026-11-21T00:00:00Z"
        XCTAssertFalse(RailLogic.isDismissed(updatedDirect, in: dismissed))

        // Restore brings it back
        let restored = RailLogic.restore([directPR], from: dismissed)
        XCTAssertTrue(restored.isEmpty)

        // JSON persistence round-trip
        let prefsJson = RailLogic.encodeReviewFilterPrefs(RailLogic.ReviewFilterPrefs(direct: false, team: true))
        XCTAssertEqual(RailLogic.parseReviewFilterPrefs(prefsJson), RailLogic.ReviewFilterPrefs(direct: false, team: true))
        XCTAssertEqual(RailLogic.parseReviewFilterPrefs("not json"), RailLogic.ReviewFilterPrefs(direct: true, team: true))

        let dismissedJson = RailLogic.encodeDismissedReviews(dismissed)
        XCTAssertEqual(RailLogic.parseDismissedReviews(dismissedJson), dismissed)
        XCTAssertEqual(RailLogic.parseDismissedReviews("[]"), [:])
    }

    func testBuildModelReviewMenuNeedsYouHarnessesAndSettings() {
        let pr = samplePR()
        let review = RailLogic.ReviewInput(
            configured: true,
            requests: [pr],
            approved: 0,
            prefs: RailLogic.ReviewFilterPrefs(direct: true, team: true),
            counts: RailLogic.ReviewCounts(direct: 1, team: 0),
            dismissed: 0
        )

        let model = RailLogic.buildModel(
            dock: [],
            pathname: "/settings/runners",
            review: review,
            needsYou: 120,
            harnesses: [],
            settingsNeedYou: true
        )

        // PR item
        let prItem = model.middle[0]
        XCTAssertEqual(prItem.id, "pr")
        XCTAssertEqual(prItem.badge, AreaBadge(text: "1", tone: .accent))
        XCTAssertEqual(prItem.menu?.first?.id, "pr:o/r#7")
        XCTAssertTrue(prItem.menu?.contains(where: { $0.id == "pr.refresh" }) == true)
        XCTAssertTrue(prItem.menu?.contains(where: { $0.id == "pr.clear" }) == true)
        XCTAssertEqual(prItem.menu?.first(where: { $0.id == "pr.dismiss" })?.children?.map(\.id), ["pr.dismiss:o/r#7"])
        XCTAssertEqual(prItem.menu?.first(where: { $0.id == "pr.direct" })?.checked, true)

        // Needs you item
        let needsItem = model.middle[1]
        XCTAssertEqual(needsItem.id, "needsYou")
        XCTAssertEqual(needsItem.kind, .needsYou)
        XCTAssertEqual(needsItem.badge, AreaBadge(text: "99+", tone: .human))

        // Foot holds Settings with active + attention dot
        XCTAssertEqual(model.foot.map(\.id), ["settings"])
        XCTAssertEqual(model.foot[0].active, true)
        XCTAssertEqual(model.foot[0].badge, AreaBadge(tone: .human))

        // Unconfigured PR menu offers setup only
        let unconfigured = RailLogic.buildModel(
            dock: [],
            pathname: "/work",
            review: RailLogic.ReviewInput(configured: false),
            needsYou: 0,
            harnesses: nil,
            settingsNeedYou: false
        )
        XCTAssertNil(unconfigured.middle[0].badge)
        XCTAssertEqual(unconfigured.middle[0].menu?.map(\.id), ["pr.setup"])
        XCTAssertNil(unconfigured.middle[1].badge)
        XCTAssertEqual(unconfigured.middle.count, 2)
        XCTAssertEqual(unconfigured.foot[0].active, false)
        XCTAssertNil(unconfigured.foot[0].badge)

        // Approved fallback badge when no review requests waiting
        let approvedOnly = RailLogic.buildModel(
            dock: [],
            pathname: "/work",
            review: RailLogic.ReviewInput(configured: true, approved: 2, dismissed: 3),
            needsYou: 0,
            harnesses: nil,
            settingsNeedYou: false
        )
        XCTAssertEqual(approvedOnly.middle[0].badge, AreaBadge(text: "2", tone: .done))
        XCTAssertEqual(approvedOnly.middle[0].menu?.first(where: { $0.id == "pr.restore" })?.label, "Restore dismissed (3)")
    }

    func testHarnessRailInputsAndOrdering() {
        let now = APIDate.parse("2026-11-22T07:00:00Z")!
        let readings = [
            sampleHarness(harness: "antigravity", label: "Antigravity", connected: true, usageAvailable: false, usageCheckedAt: nil),
            sampleHarness(harness: "disconnected", label: "Off", connected: false, running: 0),
            sampleHarness(
                harness: "codex",
                label: "Codex",
                connected: true,
                running: 0,
                limitedUntil: "2026-11-22T09:00:00Z",
                usageAvailable: true,
                windows: [API.UsageWindow(id: "s", kind: .session, label: "5h", usedPercent: 100)]
            ),
            sampleHarness(
                harness: "claude-code",
                label: "Claude",
                connected: true,
                running: 2,
                usageAvailable: true,
                usageCheckedAt: "2026-11-22T06:59:20Z",
                windows: [
                    API.UsageWindow(id: "s", kind: .session, label: "5h", usedPercent: 45),
                    API.UsageWindow(id: "w", kind: .weekly, label: "Weekly", usedPercent: 18),
                ]
            ),
            sampleHarness(harness: "custom-cli", label: "Custom", connected: false, running: 1, usageAvailable: false, usageCheckedAt: nil, usageChecking: true),
        ]

        let connected = RailLogic.connectedHarnesses(readings)
        XCTAssertEqual(connected.map(\.harness), ["claude-code", "codex", "antigravity", "custom-cli"])

        let inputs = RailLogic.harnessRailInputs(connected, now: now, timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(inputs[0].initials, "CC")
        XCTAssertEqual(inputs[0].state, .working)
        XCTAssertEqual(inputs[0].usage.value, "45%")
        XCTAssertEqual(inputs[0].usage.fraction, 0.45)
        XCTAssertEqual(inputs[0].usage.meta, ["5h allowance used", "2 working"])
        XCTAssertEqual(inputs[0].usage.sub, "5h · weekly 18%")
        XCTAssertEqual(inputs[0].usage.footnote, "checked 40s ago")

        XCTAssertEqual(inputs[1].initials, "CX")
        XCTAssertEqual(inputs[1].state, .limited)
        XCTAssertEqual(inputs[1].usage.tone, .limited)
        XCTAssertEqual(inputs[1].usage.meta, ["5h allowance used", "Limited"])
        XCTAssertTrue(inputs[1].usage.sub?.contains("falls back to Claude") == true)

        XCTAssertEqual(inputs[2].name, "AG")
        XCTAssertEqual(inputs[2].usage.value, "—")
        XCTAssertEqual(inputs[2].usage.unavailable, true)
        XCTAssertEqual(inputs[2].usage.meta, ["Allowance not reported", "Idle"])

        XCTAssertEqual(inputs[3].initials, "CU")
        XCTAssertEqual(inputs[3].color, "#8A8F98")
        XCTAssertEqual(inputs[3].usage.value, "…")
        XCTAssertEqual(inputs[3].usage.meta, ["Checking usage…", "1 working"])
        XCTAssertEqual(inputs[3].usage.footnote, "checking…")

        let model = RailLogic.buildModel(
            dock: [],
            pathname: "/chat",
            review: RailLogic.ReviewInput(),
            needsYou: 0,
            harnesses: inputs,
            settingsNeedYou: false
        )
        let claudeItem = model.middle[2]
        XCTAssertEqual(claudeItem.id, "harness:claude-code")
        XCTAssertEqual(claudeItem.status, .done)
        XCTAssertEqual(claudeItem.character, RailCharacter(harness: "claude-code", working: true, name: "Claude"))
        XCTAssertEqual(claudeItem.menu?.last?.id, "usage")

        let codexItem = model.middle[3]
        XCTAssertEqual(codexItem.status, .warning)
        XCTAssertEqual(codexItem.character?.working, false)
    }

    func testSettingsNeedAttention() {
        XCTAssertFalse(RailLogic.settingsNeedAttention(nil))

        let noKey = API.SecretList(keyConfigured: false, known: [], secrets: [], signInAvailable: false)
        XCTAssertTrue(RailLogic.settingsNeedAttention(noKey))

        let missingRequired = API.SecretList(
            keyConfigured: true,
            known: [],
            secrets: [API.SecretInfo(createdAt: "2026-11-20T00:00:00Z", id: "1", name: "harness:anthropic", updatedAt: "2026-11-20T00:00:00Z")],
            signInAvailable: false
        )
        XCTAssertTrue(RailLogic.settingsNeedAttention(missingRequired))

        let complete = API.SecretList(
            keyConfigured: true,
            known: [],
            secrets: [
                API.SecretInfo(createdAt: "2026-11-20T00:00:00Z", id: "1", name: "harness:anthropic", updatedAt: "2026-11-20T00:00:00Z"),
                API.SecretInfo(createdAt: "2026-11-20T00:00:00Z", id: "2", name: "harness:openai", updatedAt: "2026-11-20T00:00:00Z"),
            ],
            signInAvailable: false
        )
        XCTAssertFalse(RailLogic.settingsNeedAttention(complete))
    }

    func testResolveAction() {
        let lookup: (String) -> String? = { id in
            switch id {
            case "a": return "https://github.com/o/r/pull/7"
            case "bad": return "javascript:alert(1)"
            default: return nil
            }
        }

        XCTAssertEqual(RailLogic.resolveAction(itemId: "dock.tab:chat", menuItemId: nil, reviewURL: lookup), .dockTab("chat"))
        XCTAssertEqual(RailLogic.resolveAction(itemId: "settings", menuItemId: nil, reviewURL: lookup), .openSettings(nil))
        XCTAssertEqual(RailLogic.resolveAction(itemId: "customization", menuItemId: nil, reviewURL: lookup), .openSettings(.pane(pane: .memory)))
        XCTAssertEqual(RailLogic.resolveAction(itemId: "needsYou", menuItemId: nil, reviewURL: lookup), .navigate("/inbox"))
        XCTAssertEqual(RailLogic.resolveAction(itemId: "pr", menuItemId: "pr.setup", reviewURL: lookup), .openSettings(.pane(pane: .secrets)))
        XCTAssertEqual(RailLogic.resolveAction(itemId: "pr", menuItemId: "pr.refresh", reviewURL: lookup), .refreshReviews)
        XCTAssertEqual(RailLogic.resolveAction(itemId: "pr", menuItemId: "pr.clear", reviewURL: lookup), .clearReviews)
        XCTAssertEqual(RailLogic.resolveAction(itemId: "pr", menuItemId: "pr.restore", reviewURL: lookup), .restoreReviews)
        XCTAssertEqual(RailLogic.resolveAction(itemId: "pr", menuItemId: "pr.direct", reviewURL: lookup), .toggleReviewPref(.direct))
        XCTAssertEqual(RailLogic.resolveAction(itemId: "pr", menuItemId: "pr.team", reviewURL: lookup), .toggleReviewPref(.team))
        XCTAssertEqual(RailLogic.resolveAction(itemId: "pr", menuItemId: "pr.dismiss:a", reviewURL: lookup), .dismissReview("a"))
        XCTAssertNil(RailLogic.resolveAction(itemId: "pr", menuItemId: "pr.dismiss:", reviewURL: lookup))
        XCTAssertEqual(RailLogic.resolveAction(itemId: "pr", menuItemId: "pr:a", reviewURL: lookup), .openExternalURL(URL(string: "https://github.com/o/r/pull/7")!))
        XCTAssertNil(RailLogic.resolveAction(itemId: "pr", menuItemId: "pr:bad", reviewURL: lookup))
        XCTAssertNil(RailLogic.resolveAction(itemId: "pr", menuItemId: "pr:missing", reviewURL: lookup))
        XCTAssertEqual(RailLogic.resolveAction(itemId: "harness:codex", menuItemId: "usage", reviewURL: lookup), .openSettings(.pane(pane: .runners)))
        XCTAssertNil(RailLogic.resolveAction(itemId: "unknown", menuItemId: nil, reviewURL: lookup))
    }
}
