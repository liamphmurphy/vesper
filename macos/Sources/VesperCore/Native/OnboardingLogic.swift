import Foundation

/// Pure state, copy, validation, and sidebar-navigation helpers for Vesper's first-run
/// Welcome Wizard (originally `web/lib/onboarding.ts`, extended with the built-in apps tour).
public enum OnboardingLogic {
    public static let navId = "onboarding"
    public static let stepPrefix = "step:"
    public static let nameMax = 80
    public static let roleMax = 80

    /// Which onboarding flow to present:
    /// - `.full`: until the user completes onboarding (`onboarded_at == nil`), or when re-run via `?setup`.
    /// - `.harnessOnly`: already onboarded, but no harness is currently connected for chats.
    public enum WizardMode: String, Sendable, Equatable {
        case full
        case harnessOnly
    }

    /// 0 is the Assistant's greeting; 1–4 are the interactive setup steps.
    public enum WizardStep: Int, Sendable, Equatable, Hashable, CaseIterable {
        case greeting = 0
        case aboutYou = 1
        case connectHarness = 2
        case appTour = 3
        case firstPersona = 4

        public var title: String {
            switch self {
            case .greeting: "Welcome"
            case .aboutYou: "About you"
            case .connectHarness: "Connect a harness"
            case .appTour: "Tour of Vesper"
            case .firstPersona: "Your first persona"
            }
        }

        public var stepIcon: String {
            switch self {
            case .greeting: "star"
            case .aboutYou: "users"
            case .connectHarness: "agents"
            case .appTour: "dashboard"
            case .firstPersona: "msg"
            }
        }
    }

    public enum StepRowState: String, Sendable, Equatable {
        case done
        case current
        case todo
    }

    public static let setupSteps: [WizardStep] = [.aboutYou, .connectHarness, .appTour, .firstPersona]

    public static let setupRows: [String] = setupSteps.map(\.title)

    public static func wizardMode(me: API.User?, forceSetup: Bool = false) -> WizardMode? {
        if forceSetup { return .full }
        guard let me else { return nil }
        if me.onboardedAt == nil || me.onboardedAt?.isEmpty == true {
            return .full
        }
        return me.harnessConnected == false ? .harnessOnly : nil
    }

    public static func needsWizard(me: API.User?) -> Bool {
        wizardMode(me: me) != nil
    }

    public static func initialStep(for mode: WizardMode) -> WizardStep {
        mode == .harnessOnly ? .connectHarness : .greeting
    }

    /// Progress fraction (0.0...1.0): each step counts once it is finished.
    public static func setupProgress(step: WizardStep) -> Double {
        let total = Double(setupSteps.count)
        guard total > 0 else { return 0 }
        let completed = max(0, min(step.rawValue - 1, setupSteps.count))
        return Double(completed) / total
    }

    public static func rowState(row: Int, step: WizardStep) -> StepRowState {
        if row < step.rawValue - 1 { return .done }
        return row == step.rawValue - 1 ? .current : .todo
    }

    /// "Good morning" from 05:00–11:59, "Good afternoon" until 17:59, then "Good evening".
    public static func greeting(hour: Int) -> String {
        if (5..<12).contains(hour) { return "Good morning" }
        if (12..<18).contains(hour) { return "Good afternoon" }
        return "Good evening"
    }

    /// What the default Assistant says above each step's card.
    public static func assistantLine(step: WizardStep, mode: WizardMode = .full, hour: Int) -> String {
        if mode == .harnessOnly {
            return "Chats need a mind to run on again: connect Claude Code, Codex, Antigravity or any mix."
        }
        switch step {
        case .greeting:
            return "\(greeting(hour: hour)). I’m your Assistant. Let’s get Vesper ready for you; it takes about a minute."
        case .aboutYou:
            return "First, how should I address you, and what do you do? Every persona will know this from the first message."
        case .connectHarness:
            return "Next, I need a mind to run on. Connect Claude Code, Codex, Antigravity or any mix."
        case .appTour:
            return "Here’s a quick tour of Vesper’s built-in apps—everything you can jump into from the sidebar."
        case .firstPersona:
            return "Lastly, who else would you like to talk to? Describe them in your own words and I’ll draft them."
        }
    }

    // MARK: - Sidebar progress navigator

    public static func sidebarNavModel(mode: WizardMode, step: WizardStep) -> NavModel {
        let steps: [WizardStep] = mode == .harnessOnly ? [.connectHarness] : setupSteps
        let items: [NavItem] = steps.enumerated().map { idx, itemStep in
            let state: StepRowState = mode == .harnessOnly ? .current : rowState(row: idx, step: step)
            let status: Tone? = switch state {
            case .done: .done
            case .current: .accent
            case .todo: nil
            }
            let trailing: String? = switch state {
            case .done: "Done"
            case .current: "Now"
            case .todo: nil
            }
            return NavItem(
                id: "\(stepPrefix)\(itemStep.rawValue)",
                title: itemStep.title,
                icon: state == .done ? "check" : itemStep.stepIcon,
                status: status,
                trailing: trailing,
                disabled: state != .done
            )
        }
        let selectedId = steps.contains(step) ? "\(stepPrefix)\(step.rawValue)" : nil
        return NavModel(
            id: navId,
            title: "Getting set up",
            sections: [
                NavSection(
                    id: "onboarding-steps",
                    title: mode == .harnessOnly ? "Harness required" : "Setup steps",
                    items: items
                ),
            ],
            selectedId: selectedId
        )
    }

    /// Maps a click on a completed sidebar row back to its wizard step.
    public static func stepFromNavCommand(_ command: NativeCommand) -> WizardStep? {
        guard case .navActivate(navId, let itemId, _) = command,
              itemId.hasPrefix(stepPrefix),
              let raw = Int(itemId.dropFirst(stepPrefix.count)),
              let step = WizardStep(rawValue: raw)
        else { return nil }
        return step
    }

    // MARK: - Profile helpers

    /// The photo circle's live letter as the person types their name.
    public static func initialOf(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    /// First-boot placeholder name isn't worth prefilling.
    public static func prefillName(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Local user" ? "" : trimmed
    }

    /// First-boot placeholder email isn't worth prefilling.
    public static func prefillEmail(_ email: String?) -> String {
        let trimmed = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        return trimmed.isEmpty || lower == "me@localhost" || lower == "me@localhost.com" ? "" : trimmed
    }

    public static func isValidRole(_ role: String) -> Bool {
        role.trimmingCharacters(in: .whitespacesAndNewlines).count <= roleMax
    }

    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= nameMax
    }

    /// Builds a `ProfilePatch` that updates name & role and promotes a typed email to primary
    /// without clearing existing addresses when the optional email field is left blank.
    public static func profilePatch(
        name: String,
        role: String,
        email: String,
        existingEmails: [String]?
    ) -> API.ProfilePatch {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        var emailsPatch: [String]?
        if !cleanEmail.isEmpty {
            var list = (existingEmails ?? []).filter { $0.caseInsensitiveCompare(cleanEmail) != .orderedSame }
            list.insert(cleanEmail, at: 0)
            emailsPatch = list
        }
        return API.ProfilePatch(
            emails: emailsPatch,
            name: cleanName,
            roleTitle: cleanRole
        )
    }

    /// Save "What I do" to Assistant memory once, not again when setup is re-run unchanged.
    public static func shouldSaveWorkMemory(role: String, previousRole: String?) -> Bool {
        let clean = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let prev = (previousRole ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean != prev
    }

    // MARK: - Harness setup helpers

    public struct HarnessCardSpec: Sendable, Equatable, Identifiable {
        public let harness: API.Harness
        public let label: String
        public let by: String
        public let images: Bool
        public let subscriptionOnly: Bool
        public let secretName: String
        public let signInProvider: API.SignInProvider

        public var id: String { harness.rawValue }
    }

    public static let harnessCards: [HarnessCardSpec] = [
        HarnessCardSpec(
            harness: .claudeCode,
            label: "Claude Code",
            by: "Anthropic · subscription or API key",
            images: false,
            subscriptionOnly: false,
            secretName: "harness:anthropic",
            signInProvider: .claude
        ),
        HarnessCardSpec(
            harness: .codex,
            label: "Codex",
            by: "OpenAI · subscription or API key",
            images: true,
            subscriptionOnly: false,
            secretName: "harness:openai",
            signInProvider: .codex
        ),
        HarnessCardSpec(
            harness: .antigravity,
            label: "Antigravity",
            by: "Google · Antigravity sign-in",
            images: true,
            subscriptionOnly: true,
            secretName: "harness:google",
            signInProvider: .antigravity
        ),
    ]

    public static let imageHarnesses: Set<API.Harness> = [.codex, .antigravity]

    public static func credentialPlaceholder(
        harness: API.Harness,
        kind: API.HarnessVerifyRequest.Kind
    ) -> String {
        if harness == .antigravity { return "Paste Antigravity login" }
        if harness == .codex {
            return kind == .subscription ? "Paste auth.json" : "OPENAI_API_KEY"
        }
        return kind == .subscription ? "Paste .credentials.json or setup-token" : "ANTHROPIC_API_KEY"
    }

    public static func credentialHelp(
        harness: API.Harness,
        kind: API.HarnessVerifyRequest.Kind
    ) -> String {
        if harness == .antigravity {
            return "Sign in with Google Antigravity above, or paste a saved Antigravity login bundle."
        }
        if harness == .codex {
            return kind == .subscription
                ? "Sign in above, or run `codex login` and paste ~/.codex/auth.json."
                : "An OpenAI API key from platform.openai.com (starts with sk-)."
        }
        return kind == .subscription
            ? "Sign in above, or paste ~/.claude/.credentials.json from `claude auth login --claudeai` or a setup-token from `claude setup-token`."
            : "An Anthropic API key from console.anthropic.com (starts with sk-ant-)."
    }

    /// Which verified harness runs the persona-drafting step (Claude Code preferred when connected).
    public static func setupHarness(verified: [API.Harness]) -> API.Harness? {
        if verified.contains(.claudeCode) { return .claudeCode }
        return verified.first
    }

    public static func harnessHint(verified: [API.Harness]) -> String {
        if verified.isEmpty { return "Connect at least one to continue." }
        let hasImage = verified.contains { imageHarnesses.contains($0) }
        return hasImage ? "" : "Image generation stays off until Codex or Antigravity is connected."
    }

    /// Harnesses already reported available by `GET /chat-models`, mapped to their model counts.
    public static func alreadyVerifiedHarnesses(from groups: [API.ChatHarnessModels]) -> [API.Harness: Int] {
        var out: [API.Harness: Int] = [:]
        for group in groups where group.available && !group.models.isEmpty {
            out[group.harness] = group.models.count
        }
        return out
    }

    // MARK: - Default apps tour

    public struct AppTourItem: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let icon: String
        public let badge: String
        public let tagline: String
        public let summary: String
        public let highlights: [String]
        public let subTools: [String]
        public let href: String

        public init(
            id: String,
            name: String,
            icon: String,
            badge: String,
            tagline: String,
            summary: String,
            highlights: [String],
            subTools: [String] = [],
            href: String
        ) {
            self.id = id
            self.name = name
            self.icon = icon
            self.badge = badge
            self.tagline = tagline
            self.summary = summary
            self.highlights = highlights
            self.subTools = subTools
            self.href = href
        }
    }

    public static let defaultAppTour: [AppTourItem] = [
        AppTourItem(
            id: "chat",
            name: "Chat",
            icon: "msg",
            badge: "Conversations",
            tagline: "Talk with personas, run coding turns, and use Live Voice",
            summary: "Your main workspace for talking with your Assistant and custom personas—with live diffs, interactive canvases, second opinions, and hands-free Live Voice.",
            highlights: [
                "Switch personas or @mention several in the same thread",
                "Inspect code diffs, live app playgrounds, and rich interactive cards",
                "Switch into Live Voice for real-time spoken conversations",
            ],
            href: "/chat"
        ),
        AppTourItem(
            id: "spaces",
            name: "Spaces",
            icon: "spaces",
            badge: "Projects",
            tagline: "Focused hubs for repos, chats, Knowledge, and tasks",
            summary: "Group everything around a project or topic into a Space. Attach GitHub repositories, link Knowledge pages, track tasks, and assign a default persona.",
            highlights: [
                "Share context, instructions, and connectors across every chat in a Space",
                "Attach git repositories to branch, test, and open pull requests",
                "Keep Space-specific tasks and code reviews in one view",
            ],
            href: "/spaces"
        ),
        AppTourItem(
            id: "knowledge",
            name: "Knowledge",
            icon: "wiki",
            badge: "Notes & Docs",
            tagline: "Linked Markdown notes, Docs, Slides, Designs, and graph",
            summary: "Your personal notes and shared agent wiki live together—with an Obsidian-style explorer, rich Docs, slide decks, UI Designs, and a live link graph.",
            highlights: [
                "Organize folders and [[wikilinks]] with an interactive graph view",
                "Draft and collaborate on Docs, Slides, and UI Designs alongside chat",
                "Review or approve edits your personas suggest to your wiki",
            ],
            href: "/knowledge"
        ),
        AppTourItem(
            id: "library",
            name: "Library",
            icon: "library",
            badge: "Media & Files",
            tagline: "Every image, video, audio track, PDF, and saved link",
            summary: "Everything your personas generate or you save lands in Library. Filter by media type, preview with Quick Look, or embed straight into Knowledge.",
            highlights: [
                "Browse generated images, videos, music, PDFs, and saved links",
                "Quick Look previews and one-click Knowledge embeds",
                "Pin reference portraits for consistent persona and personal likeness",
            ],
            href: "/library"
        ),
        AppTourItem(
            id: "browser",
            name: "Browser",
            icon: "compass",
            badge: "Web",
            tagline: "Built-in tabbed browser you can share live with personas",
            summary: "Read docs, dashboards, and references right inside Vesper—with built-in ad and tracker blocking and one-click tab sharing into any chat.",
            highlights: [
                "Native tabs, bookmarks, and content blocking out of the box",
                "Share your active page directly so a persona sees what you see",
                "Open links inside Vesper by default, or Option-click for Safari",
            ],
            href: "/browser"
        ),
        AppTourItem(
            id: "apps",
            name: "Apps & Tools",
            icon: "dashboard",
            badge: "Workbench",
            tagline: "Built-in power tools plus your own SQLite Custom Apps",
            summary: "Open the Apps icon in the sidebar for Vesper’s built-in workbench tools—and ask any persona to scaffold sandboxed Custom Apps with their own SQLite database.",
            highlights: [
                "Build visual Workflows and recurring Scheduled automations",
                "Study with guided Learn courses, inspect Reports, and test APIs in HTTP Client",
                "Create persistent Custom Apps that can even open in standalone windows",
            ],
            subTools: ["Workflows", "Scheduled", "Learn", "Reports", "HTTP Client", "Custom Apps"],
            href: "/apps"
        ),
    ]

    public static func nextTourIndex(from current: Int, count: Int = defaultAppTour.count) -> Int? {
        guard count > 0, current + 1 < count else { return nil }
        return max(0, current + 1)
    }

    public static func previousTourIndex(from current: Int) -> Int? {
        guard current > 0 else { return nil }
        return current - 1
    }

    // MARK: - Natural-language persona drafting helpers

    public static let personaExamples: [String] = [
        "A blunt senior engineer who pairs with me",
        "A dry-witted D&D dungeon master",
        "A calm health coach",
    ]

    /// The hidden setup chat's initial message. `(Vesper setup)` is also recognised by
    /// `server/cmd/fake-harness` (`fakeSetupPersona`), which proposes a persona in reply.
    public static func draftPrompt(_ description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return "(Vesper setup) I’m setting up Vesper and would like a new persona to talk to. In my words: \"\(trimmed)\"\n\n"
            + "Call propose_persona once now with a short, memorable name, a fitting tone and colour, instructions written to it in the second person "
            + "(three or four short sentences on how it works and what it focuses on) and a one-sentence reason. Give it a profile picture with "
            + "avatar_prompt only if you can make images. Then reply with one short sentence."
    }

    public static func refinePrompt(_ change: String) -> String {
        let trimmed = change.trimmingCharacters(in: .whitespacesAndNewlines)
        return "(Vesper setup) Change the draft: \"\(trimmed)\"\n\nCall propose_persona again with the whole updated persona, then reply with one short sentence."
    }

    /// Up to three concise bullets extracted from a drafted persona's instructions.
    public static func draftBullets(_ instructions: String) -> [String] {
        let raw = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        let normalized = raw.replacingOccurrences(of: #"(?<=[.!?])\s+|\n+"#, with: "\n", options: .regularExpression)
        var out: [String] = []
        for piece in normalized.split(separator: "\n") {
            var line = String(piece).trimmingCharacters(in: .whitespacesAndNewlines)
            line = line.replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
            if line.hasSuffix(".") || line.hasSuffix("!") {
                line.removeLast()
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            line = line.replacingOccurrences(of: #"^[Yy]ou\s+"#, with: "", options: .regularExpression)
            guard let first = line.first else { continue }
            out.append(first.uppercased() + line.dropFirst())
            if out.count == 3 { break }
        }
        return out
    }

    public struct DraftEvaluation: Sendable, Equatable {
        public let fresh: API.PersonaProposal?
        public let draft: API.PersonaProposal?
        public let failed: Bool
        public let waiting: Bool
        public let ready: Bool
    }

    /// Evaluates the hidden setup chat's proposals relative to the last send so we know whether
    /// a fresh draft arrived, is still being drafted/imaged, or the turn ended without proposing one.
    public static func evaluateDraft(
        proposals: [API.PersonaProposal],
        beforeIds: Set<String>,
        sentAt: Date?,
        chatRunning: Bool?,
        chatUpdatedAt: Date?,
        proposalsUpdatedAt: Date?
    ) -> DraftEvaluation {
        let fresh = proposals.last { !beforeIds.contains($0.id) && $0.state == .pending }
        let draft = fresh ?? proposals.last { $0.state == .pending }
        let settled = fresh != nil && fresh?.avatarState != .pending
        let turnOver: Bool
        if let sentAt, let chatRunning, let chatUpdatedAt {
            turnOver = !chatRunning && chatUpdatedAt > sentAt
        } else {
            turnOver = false
        }
        let failed: Bool
        if sentAt != nil, fresh == nil, turnOver,
           let proposalsUpdatedAt, let chatUpdatedAt, proposalsUpdatedAt >= chatUpdatedAt {
            failed = true
        } else {
            failed = false
        }
        let waiting = sentAt != nil && !settled && !failed
        let ready = draft != nil && draft?.avatarState != .pending
        return DraftEvaluation(fresh: fresh, draft: draft, failed: failed, waiting: waiting, ready: ready)
    }
}
