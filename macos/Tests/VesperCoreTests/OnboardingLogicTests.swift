import XCTest
@testable import VesperCore

final class OnboardingLogicTests: XCTestCase {
    private func makeUser(
        name: String = "Local user",
        email: String = "me@localhost",
        roleTitle: String = "",
        onboardedAt: String? = nil,
        harnessConnected: Bool? = false
    ) -> API.User {
        API.User(
            email: email,
            emails: [email],
            harnessConnected: harnessConnected,
            id: "u1",
            initials: "LU",
            name: name,
            onboardedAt: onboardedAt,
            roleTitle: roleTitle
        )
    }

    private func makeProposal(
        id: String,
        name: String = "Hackerman",
        state: API.PersonaProposal.State = .pending,
        avatarState: API.PersonaProposal.AvatarState? = nil
    ) -> API.PersonaProposal {
        API.PersonaProposal(
            avatarState: avatarState,
            chatId: "c1",
            color: "#f2a97e",
            createdAt: "2026-11-28T00:00:00Z",
            customInstructions: "You reproduce a bug before fixing it. You lead with the answer. You push back with alternatives.",
            id: id,
            name: name,
            reason: "An engineering partner to pair with.",
            state: state,
            tone: .concise
        )
    }

    func testWizardModeTransitions() {
        XCTAssertNil(OnboardingLogic.wizardMode(me: nil))
        XCTAssertEqual(OnboardingLogic.wizardMode(me: nil, forceSetup: true), .full)

        let fresh = makeUser(onboardedAt: nil, harnessConnected: true)
        XCTAssertEqual(OnboardingLogic.wizardMode(me: fresh), .full)
        XCTAssertTrue(OnboardingLogic.needsWizard(me: fresh))
        XCTAssertEqual(OnboardingLogic.initialStep(for: .full), .greeting)

        let missingHarness = makeUser(onboardedAt: "2026-11-20T00:00:00Z", harnessConnected: false)
        XCTAssertEqual(OnboardingLogic.wizardMode(me: missingHarness), .harnessOnly)
        XCTAssertTrue(OnboardingLogic.needsWizard(me: missingHarness))
        XCTAssertEqual(OnboardingLogic.initialStep(for: .harnessOnly), .connectHarness)

        let ready = makeUser(onboardedAt: "2026-11-20T00:00:00Z", harnessConnected: true)
        XCTAssertNil(OnboardingLogic.wizardMode(me: ready))
        XCTAssertFalse(OnboardingLogic.needsWizard(me: ready))
        XCTAssertEqual(OnboardingLogic.wizardMode(me: ready, forceSetup: true), .full)

        // Older servers omitting harness_connected only gate on onboarded_at.
        let legacy = makeUser(onboardedAt: "2026-11-20T00:00:00Z", harnessConnected: nil)
        XCTAssertNil(OnboardingLogic.wizardMode(me: legacy))
    }

    func testProgressRowStatesAndGreetingByHour() {
        XCTAssertEqual(OnboardingLogic.setupRows, ["About you", "Connect a harness", "Tour of Vesper", "Your first persona"])
        XCTAssertEqual(OnboardingLogic.setupProgress(step: .greeting), 0)
        XCTAssertEqual(OnboardingLogic.setupProgress(step: .aboutYou), 0)
        XCTAssertEqual(OnboardingLogic.setupProgress(step: .connectHarness), 0.25)
        XCTAssertEqual(OnboardingLogic.setupProgress(step: .appTour), 0.5)
        XCTAssertEqual(OnboardingLogic.setupProgress(step: .firstPersona), 0.75)

        XCTAssertEqual(OnboardingLogic.rowState(row: 0, step: .aboutYou), .current)
        XCTAssertEqual(OnboardingLogic.rowState(row: 1, step: .aboutYou), .todo)
        XCTAssertEqual(OnboardingLogic.rowState(row: 0, step: .appTour), .done)
        XCTAssertEqual(OnboardingLogic.rowState(row: 1, step: .appTour), .done)
        XCTAssertEqual(OnboardingLogic.rowState(row: 2, step: .appTour), .current)
        XCTAssertEqual(OnboardingLogic.rowState(row: 3, step: .appTour), .todo)

        XCTAssertEqual(OnboardingLogic.greeting(hour: 8), "Good morning")
        XCTAssertEqual(OnboardingLogic.greeting(hour: 14), "Good afternoon")
        XCTAssertEqual(OnboardingLogic.greeting(hour: 21), "Good evening")
        XCTAssertEqual(OnboardingLogic.greeting(hour: 2), "Good evening")

        XCTAssertTrue(OnboardingLogic.assistantLine(step: .greeting, hour: 9).hasPrefix("Good morning."))
        XCTAssertTrue(OnboardingLogic.assistantLine(step: .connectHarness, mode: .harnessOnly, hour: 9).contains("need a mind to run on again"))
    }

    func testSidebarNavModelAndBackNavigationCommand() {
        let nav = OnboardingLogic.sidebarNavModel(mode: .full, step: .appTour)
        XCTAssertEqual(nav.id, OnboardingLogic.navId)
        XCTAssertEqual(nav.selectedId, "step:3")
        let items = nav.sections[0].items
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0].disabled, false) // completed steps are clickable
        XCTAssertEqual(items[0].trailing, "Done")
        XCTAssertEqual(items[1].disabled, false)
        XCTAssertEqual(items[2].disabled, true) // current step
        XCTAssertEqual(items[2].trailing, "Now")
        XCTAssertEqual(items[3].disabled, true) // future step

        XCTAssertEqual(
            OnboardingLogic.stepFromNavCommand(.navActivate(navigatorId: OnboardingLogic.navId, itemId: "step:1")),
            .aboutYou
        )
        XCTAssertNil(
            OnboardingLogic.stepFromNavCommand(.navActivate(navigatorId: ChatNav.id, itemId: "step:1"))
        )

        let harnessNav = OnboardingLogic.sidebarNavModel(mode: .harnessOnly, step: .connectHarness)
        XCTAssertEqual(harnessNav.sections[0].items.count, 1)
        XCTAssertEqual(harnessNav.selectedId, "step:2")
    }

    func testProfileHelpersAndWorkMemoryGuard() {
        XCTAssertEqual(OnboardingLogic.initialOf("  ada lovelace"), "A")
        XCTAssertEqual(OnboardingLogic.initialOf("   "), "?")
        XCTAssertEqual(OnboardingLogic.prefillName("Local user"), "")
        XCTAssertEqual(OnboardingLogic.prefillName("Ada"), "Ada")
        XCTAssertEqual(OnboardingLogic.prefillEmail("me@localhost"), "")
        XCTAssertEqual(OnboardingLogic.prefillEmail("ME@LOCALHOST.COM"), "")
        XCTAssertEqual(OnboardingLogic.prefillEmail("ada@example.com"), "ada@example.com")

        XCTAssertFalse(OnboardingLogic.isValidName("   "))
        XCTAssertTrue(OnboardingLogic.isValidName("Ada"))
        XCTAssertTrue(OnboardingLogic.isValidRole(String(repeating: "a", count: 80)))
        XCTAssertFalse(OnboardingLogic.isValidRole(String(repeating: "a", count: 81)))

        let patchNoEmail = OnboardingLogic.profilePatch(name: " Ada ", role: " Engineer ", email: "  ", existingEmails: ["me@localhost"])
        XCTAssertEqual(patchNoEmail.name, "Ada")
        XCTAssertEqual(patchNoEmail.roleTitle, "Engineer")
        XCTAssertNil(patchNoEmail.emails)

        let patchWithEmail = OnboardingLogic.profilePatch(
            name: "Ada",
            role: "Engineer",
            email: "ada@example.com",
            existingEmails: ["me@localhost", "ADA@EXAMPLE.COM"]
        )
        XCTAssertEqual(patchWithEmail.emails, ["ada@example.com", "me@localhost"])

        XCTAssertTrue(OnboardingLogic.shouldSaveWorkMemory(role: "Backend engineer", previousRole: ""))
        XCTAssertFalse(OnboardingLogic.shouldSaveWorkMemory(role: "Backend engineer", previousRole: "Backend engineer"))
        XCTAssertFalse(OnboardingLogic.shouldSaveWorkMemory(role: "   ", previousRole: ""))
    }

    func testHarnessHelpers() {
        XCTAssertEqual(OnboardingLogic.harnessCards.map(\.harness), [.claudeCode, .codex, .antigravity])
        XCTAssertEqual(OnboardingLogic.harnessHint(verified: []), "Connect at least one to continue.")
        XCTAssertEqual(OnboardingLogic.harnessHint(verified: [.claudeCode]), "Image generation stays off until Codex or Antigravity is connected.")
        XCTAssertEqual(OnboardingLogic.harnessHint(verified: [.claudeCode, .codex]), "")
        XCTAssertEqual(OnboardingLogic.harnessHint(verified: [.antigravity]), "")

        XCTAssertEqual(OnboardingLogic.setupHarness(verified: [.codex, .claudeCode]), .claudeCode)
        XCTAssertEqual(OnboardingLogic.setupHarness(verified: [.codex]), .codex)
        XCTAssertNil(OnboardingLogic.setupHarness(verified: []))

        XCTAssertEqual(OnboardingLogic.credentialPlaceholder(harness: .claudeCode, kind: .apiKey), "ANTHROPIC_API_KEY")
        XCTAssertEqual(OnboardingLogic.credentialPlaceholder(harness: .codex, kind: .subscription), "Paste auth.json")
        XCTAssertEqual(OnboardingLogic.credentialPlaceholder(harness: .antigravity, kind: .subscription), "Paste Antigravity login")

        let groups = [
            API.ChatHarnessModels(available: true, harness: .claudeCode, label: "Claude Code", models: [
                API.ChatModel(default: true, efforts: [], id: "claude-sonnet", label: "Sonnet"),
                API.ChatModel(default: false, efforts: [], id: "claude-opus", label: "Opus"),
            ]),
            API.ChatHarnessModels(available: false, harness: .codex, label: "Codex", models: []),
        ]
        XCTAssertEqual(OnboardingLogic.alreadyVerifiedHarnesses(from: groups), [.claudeCode: 2])
    }

    func testDefaultAppsTourCoverageAndStepping() {
        let ids = OnboardingLogic.defaultAppTour.map(\.id)
        XCTAssertEqual(ids, ["chat", "spaces", "knowledge", "library", "browser", "apps"])
        XCTAssertTrue(OnboardingLogic.defaultAppTour.allSatisfy { !$0.highlights.isEmpty && !$0.summary.isEmpty })
        let appsTour = OnboardingLogic.defaultAppTour.last
        XCTAssertEqual(appsTour?.subTools, ["Workflows", "Scheduled", "Learn", "Reports", "HTTP Client", "Custom Apps"])

        XCTAssertNil(OnboardingLogic.previousTourIndex(from: 0))
        XCTAssertEqual(OnboardingLogic.previousTourIndex(from: 2), 1)
        XCTAssertEqual(OnboardingLogic.nextTourIndex(from: 0), 1)
        XCTAssertNil(OnboardingLogic.nextTourIndex(from: ids.count - 1))
    }

    func testPersonaDraftPromptsBulletsAndEvaluation() {
        let initial = OnboardingLogic.draftPrompt("A blunt senior engineer")
        XCTAssertTrue(initial.hasPrefix("(Vesper setup)"))
        XCTAssertTrue(initial.contains("propose_persona"))
        XCTAssertTrue(initial.contains("A blunt senior engineer"))

        let refine = OnboardingLogic.refinePrompt("Make them more playful")
        XCTAssertTrue(refine.hasPrefix("(Vesper setup) Change the draft:"))
        XCTAssertTrue(refine.contains("Make them more playful"))

        let bullets = OnboardingLogic.draftBullets(
            "You reproduce a bug before fixing it. You lead with the answer. You push back with alternatives. You also write tests."
        )
        XCTAssertEqual(bullets, [
            "Reproduce a bug before fixing it",
            "Lead with the answer",
            "Push back with alternatives",
        ])

        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 1005)
        let t2 = Date(timeIntervalSince1970: 1006)

        // Waiting while turn is still running with no new proposal
        let running = OnboardingLogic.evaluateDraft(
            proposals: [],
            beforeIds: [],
            sentAt: t0,
            chatRunning: true,
            chatUpdatedAt: t1,
            proposalsUpdatedAt: t1
        )
        XCTAssertTrue(running.waiting)
        XCTAssertFalse(running.failed)
        XCTAssertFalse(running.ready)

        // Fresh proposal with pending avatar stays waiting and not yet ready
        let avatarPending = OnboardingLogic.evaluateDraft(
            proposals: [makeProposal(id: "p1", avatarState: .pending)],
            beforeIds: [],
            sentAt: t0,
            chatRunning: false,
            chatUpdatedAt: t1,
            proposalsUpdatedAt: t2
        )
        XCTAssertTrue(avatarPending.waiting)
        XCTAssertFalse(avatarPending.ready)
        XCTAssertEqual(avatarPending.draft?.id, "p1")

        // Fresh proposal settled (no avatar or ready) is ready to meet
        let settled = OnboardingLogic.evaluateDraft(
            proposals: [makeProposal(id: "p1", avatarState: .ready)],
            beforeIds: [],
            sentAt: t0,
            chatRunning: false,
            chatUpdatedAt: t1,
            proposalsUpdatedAt: t2
        )
        XCTAssertFalse(settled.waiting)
        XCTAssertFalse(settled.failed)
        XCTAssertTrue(settled.ready)
        XCTAssertEqual(settled.fresh?.id, "p1")

        // Turn finished after sentAt with no new proposal -> failed
        let failed = OnboardingLogic.evaluateDraft(
            proposals: [makeProposal(id: "old", state: .declined)],
            beforeIds: ["old"],
            sentAt: t0,
            chatRunning: false,
            chatUpdatedAt: t1,
            proposalsUpdatedAt: t2
        )
        XCTAssertFalse(failed.waiting)
        XCTAssertTrue(failed.failed)
        XCTAssertFalse(failed.ready)
    }
}
