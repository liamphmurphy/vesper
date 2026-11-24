import Foundation
import XCTest
@testable import VesperCore

final class ChatComposerLogicTests: XCTestCase {
    // MARK: - @mention Detection, Ranking & Insertion

    func testMentionTriggerDetectsStartAndMidSentence() {
        let start = ChatMentionLogic.detectTrigger(in: "@me", cursorUTF16: 3)
        XCTAssertEqual(start, ChatMentionTrigger(query: "me", utf16Location: 0, utf16Length: 3))

        let mid = ChatMentionLogic.detectTrigger(in: "Hey @tech", cursorUTF16: 9)
        XCTAssertEqual(mid, ChatMentionTrigger(query: "tech", utf16Location: 4, utf16Length: 5))
    }

    func testMentionTriggerIgnoresEmailsAndInlineCode() {
        XCTAssertNil(ChatMentionLogic.detectTrigger(in: "mail user@example", cursorUTF16: 17))
        XCTAssertNil(ChatMentionLogic.detectTrigger(in: "Run `@meow", cursorUTF16: 10))
        XCTAssertNotNil(ChatMentionLogic.detectTrigger(in: "Run `ls` @meow", cursorUTF16: 14))
    }

    func testMentionRankingPrioritizesParticipantsAndExactPrefixMatches() {
        let candidates = [
            ChatMentionCandidate(id: "p1", name: "Mastermind", handle: "mastermind", isDefault: false, inChatList: true),
            ChatMentionCandidate(id: "p2", name: "Meow", handle: "meow", isDefault: true, inChatList: true),
            ChatMentionCandidate(id: "p3", name: "Dr. Mara", handle: "mara", isDefault: false, inChatList: true),
            ChatMentionCandidate(id: "p4", name: "Hidden", handle: "hidden", isDefault: false, inChatList: false),
        ]

        let rankedEmpty = ChatMentionLogic.rankCandidates(candidates, query: "", participantIds: ["p3"])
        XCTAssertEqual(rankedEmpty.map(\.id), ["p3", "p2", "p1"])

        let rankedM = ChatMentionLogic.rankCandidates(candidates, query: "m", participantIds: ["p1"])
        XCTAssertEqual(rankedM.first?.id, "p1")
        XCTAssertFalse(rankedM.contains { $0.id == "p4" })

        let rankedHandle = ChatMentionLogic.rankCandidates(candidates, query: "mara")
        XCTAssertEqual(rankedHandle.map(\.id), ["p3"])
    }

    func testMentionInsertionReplacesTriggerAndAdvancesCursor() {
        let text = "Ask @me about this"
        let trigger = ChatMentionLogic.detectTrigger(in: text, cursorUTF16: 7)!
        let candidate = ChatMentionCandidate(id: "p2", name: "Meow")
        let result = ChatMentionLogic.insertMention(candidate, into: text, trigger: trigger)
        XCTAssertEqual(result.text, "Ask @Meow  about this")
        XCTAssertEqual(result.cursorUTF16, 10)
    }

    // MARK: - Slash Commands

    func testSlashCommandParsingMatchesWebRules() {
        XCTAssertEqual(ChatSlashCommandLogic.parseCommand("/aside what changed?"), ChatParsedCommand(name: "aside", arg: "what changed?"))
        XCTAssertEqual(ChatSlashCommandLogic.parseCommand("/compact   focus on auth  "), ChatParsedCommand(name: "compact", arg: "focus on auth"))
        XCTAssertEqual(ChatSlashCommandLogic.parseCommand("/new"), ChatParsedCommand(name: "new", arg: ""))
        XCTAssertNil(ChatSlashCommandLogic.parseCommand("/usr/bin/env"))
        XCTAssertNil(ChatSlashCommandLogic.parseCommand("//literal slash"))
        XCTAssertNil(ChatSlashCommandLogic.parseCommand("/aside line1\nline2"))
        XCTAssertEqual(ChatSlashCommandLogic.literalBody("//hello"), "/hello")
        XCTAssertEqual(ChatSlashCommandLogic.literalBody("hello"), "hello")
        XCTAssertEqual(ChatSlashCommandLogic.designRequest("  auth flow "), "Create a design: auth flow")
    }

    func testSlashCommandMenuStagesAndCompareDismissal() {
        XCTAssertEqual(ChatSlashCommandLogic.commandMenu(for: "/"), .command(query: ""))
        XCTAssertEqual(ChatSlashCommandLogic.commandMenu(for: "/co"), .command(query: "co"))
        XCTAssertEqual(ChatSlashCommandLogic.commandMenu(for: "/model op"), .arg(name: "model", query: "op"))
        XCTAssertEqual(ChatSlashCommandLogic.commandMenu(for: "/compare cod"), .arg(name: "compare", query: "cod"))
        // Once space follows model token in /compare, close picker so Enter submits
        XCTAssertNil(ChatSlashCommandLogic.commandMenu(for: "/compare codex check this"))
        // Free commands don't open arg picker
        XCTAssertNil(ChatSlashCommandLogic.commandMenu(for: "/steer focus on tests"))
        XCTAssertNil(ChatSlashCommandLogic.commandMenu(for: "/aside quick question"))
        XCTAssertNil(ChatSlashCommandLogic.commandMenu(for: "/queue next step"))
    }

    func testSlashCommandMatchingAndCompareResolution() {
        let matches = ChatSlashCommandLogic.matchingCommands(query: "co")
        XCTAssertEqual(matches.prefix(2).map(\.name), ["compact", "compare"])

        let options = [
            ChatCompareOption(name: "Claude Code Opus", harness: "claude-code", harnessLabel: "Claude Code", model: "opus", modelLabel: "Opus", isDefault: true),
            ChatCompareOption(name: "Codex GPT-5", harness: "codex", harnessLabel: "Codex", model: "gpt-5", modelLabel: "GPT-5", isDefault: true),
        ]

        if case .matched(let opt, let q) = ChatSlashCommandLogic.resolveCompareTarget(options: options, raw: "codex review the diff") {
            XCTAssertEqual(opt.model, "gpt-5")
            XCTAssertEqual(q, "review the diff")
        } else {
            XCTFail("Expected codex match")
        }

        if case .error(let msg) = ChatSlashCommandLogic.resolveCompareTarget(options: options, raw: "nonexistent") {
            XCTAssertTrue(msg.contains("nonexistent"))
        } else {
            XCTFail("Expected error for unknown model")
        }
    }

    func testThinkingSlashCommandParsingMenuAndPreferencePersistence() {
        XCTAssertEqual(ChatSlashCommandLogic.commandMenu(for: "/th"), .command(query: "th"))
        XCTAssertEqual(ChatSlashCommandLogic.commandMenu(for: "/thinking "), .arg(name: "thinking", query: ""))
        XCTAssertEqual(ChatSlashCommandLogic.commandMenu(for: "/thinking o"), .arg(name: "thinking", query: "o"))
        XCTAssertEqual(ChatSlashCommandLogic.parseCommand("/thinking"), ChatParsedCommand(name: "thinking", arg: ""))
        XCTAssertEqual(ChatSlashCommandLogic.parseCommand("/thinking on"), ChatParsedCommand(name: "thinking", arg: "on"))
        XCTAssertEqual(ChatSlashCommandLogic.parseCommand("/thinking OFF"), ChatParsedCommand(name: "thinking", arg: "OFF"))

        XCTAssertEqual(ChatSlashCommandLogic.resolveThinkingToggle(raw: "", current: false), .set(true))
        XCTAssertEqual(ChatSlashCommandLogic.resolveThinkingToggle(raw: "", current: true), .set(false))
        XCTAssertEqual(ChatSlashCommandLogic.resolveThinkingToggle(raw: "on", current: false), .set(true))
        XCTAssertEqual(ChatSlashCommandLogic.resolveThinkingToggle(raw: "off", current: true), .set(false))
        XCTAssertEqual(ChatSlashCommandLogic.resolveThinkingToggle(raw: "bogus", current: false), .error("Usage: /thinking [on|off]"))

        let suiteName = "VesperLiveThinkingPrefTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(ChatLiveThinkingPreference.read(from: defaults))
        ChatLiveThinkingPreference.write(true, to: defaults)
        XCTAssertTrue(ChatLiveThinkingPreference.read(from: defaults))
        ChatLiveThinkingPreference.write(false, to: defaults)
        XCTAssertFalse(ChatLiveThinkingPreference.read(from: defaults))
    }

    // MARK: - Per-Chat Draft Store

    func testDraftStoreSavesRestoresAndClearsPerChat() {
        let suiteName = "VesperChatDraftTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ChatDraftStore(defaults: defaults, keyPrefix: "Draft.")
        let chip = ChatContextChip(kind: .ticket, label: "LAZYAGENTS-286", refKey: "LAZYAGENTS-286")
        let draftA = ChatComposerDraft(text: "Working on composer", chips: [chip])
        let draftNew = ChatComposerDraft(text: "Brand new chat draft")

        store.save(draftA, chatId: "chat-1")
        store.save(draftNew, chatId: nil)

        XCTAssertEqual(store.load(chatId: "chat-1")?.text, "Working on composer")
        XCTAssertEqual(store.load(chatId: "chat-1")?.chips, [chip])
        XCTAssertEqual(store.load(chatId: nil)?.text, "Brand new chat draft")
        XCTAssertNil(store.load(chatId: "chat-2"))

        // Saving empty text & no chips removes the stored draft
        store.save(ChatComposerDraft(text: "   \n ", chips: []), chatId: "chat-1")
        XCTAssertNil(store.load(chatId: "chat-1"))

        store.clear(chatId: nil)
        XCTAssertNil(store.load(chatId: nil))
    }

    // MARK: - Attachments

    func testAttachmentValidationNamingAndBadges() {
        XCTAssertNil(ChatAttachmentRules.problem(filename: "spec.pdf", sizeBytes: 1024))
        XCTAssertEqual(ChatAttachmentRules.problem(filename: "malware.exe", sizeBytes: 100), "type not supported")
        XCTAssertEqual(ChatAttachmentRules.problem(filename: "empty.txt", sizeBytes: 0), "file is empty")
        XCTAssertEqual(ChatAttachmentRules.problem(filename: "huge.zip", sizeBytes: ChatAttachmentRules.maxBytes + 1), "over 25 MB")
        XCTAssertNotNil(ChatAttachmentRules.canAdd(currentCount: ChatAttachmentRules.maxCount, filename: "ok.png", sizeBytes: 500))

        XCTAssertEqual(ChatAttachmentRules.pastedImageName(contentType: "image/png", index: 1), "pasted-image-1.png")
        XCTAssertEqual(ChatAttachmentRules.pastedImageName(contentType: "image/jpeg; charset=binary", index: 2), "pasted-image-2.jpg")
        XCTAssertEqual(ChatAttachmentRules.badge(for: "photo.webp"), "IMG")
        XCTAssertEqual(ChatAttachmentRules.badge(for: "report.pdf"), "PDF")
        XCTAssertEqual(ChatAttachmentRules.badge(for: "unknown.bin"), "FILE")

        XCTAssertEqual(ChatAttachmentRules.directMimeType(forImageTypeIdentifier: "public.png"), "image/png")
        XCTAssertEqual(ChatAttachmentRules.directMimeType(forImageTypeIdentifier: "public.jpeg"), "image/jpeg")
        XCTAssertEqual(ChatAttachmentRules.directMimeType(forImageTypeIdentifier: "com.compuserve.gif"), "image/gif")
        XCTAssertEqual(ChatAttachmentRules.directMimeType(forImageTypeIdentifier: "org.webmproject.webp"), "image/webp")
        XCTAssertNil(ChatAttachmentRules.directMimeType(forImageTypeIdentifier: "public.tiff"))
        XCTAssertNil(ChatAttachmentRules.directMimeType(forImageTypeIdentifier: "public.heic"))
        XCTAssertTrue(ChatAttachmentRules.pastedImageTypeIdentifiers.contains("public.png"))
        XCTAssertTrue(ChatAttachmentRules.pastedImageTypeIdentifiers.contains("public.tiff"))
        XCTAssertTrue(ChatAttachmentRules.pastedImageTypeIdentifiers.contains("public.heic"))
    }

    // MARK: - Work & Knowledge Context Serialization

    func testContextChipSerializationForWorkAndKnowledge() {
        let workChip = ChatContextChip(kind: .workTicket, label: "Native composer", refKey: "LAZYAGENTS-286", pinned: false)
        let pinnedRun = ChatContextChip(kind: .workRun, label: "Build mac", refId: "run-99", refKey: "LAZYAGENTS-286", agent: "meow", pinned: true)
        let knowledgeViewing = ChatContextChip(kind: .knowledgePage, label: "Specs/Chat.md", pinned: true)
        let knowledgeFolder = ChatContextChip(kind: .knowledgeFolder, label: "Architecture/")

        let serialized = ChatComposerContextLogic.serializeBody(
            "Check this out",
            chips: [workChip, pinnedRun, knowledgeViewing, knowledgeFolder]
        )

        XCTAssertTrue(serialized.contains(ChatContextMarker.work))
        XCTAssertTrue(serialized.contains("Pinned run run-99"))
        XCTAssertTrue(serialized.contains("Viewing ticket LAZYAGENTS-286"))
        XCTAssertTrue(serialized.contains(ChatContextMarker.knowledge))
        XCTAssertTrue(serialized.contains("Viewing page Specs/Chat.md."))
        XCTAssertTrue(serialized.contains("Attached folder Architecture/."))

        let apiTicket = ChatContextChip(kind: .ticket, label: "LAZYAGENTS-286", refKey: "LAZYAGENTS-286")
        let refs = ChatComposerContextLogic.toAPIContextRefs([workChip, apiTicket])
        XCTAssertEqual(refs?.count, 1)
        XCTAssertEqual(refs?.first?.kind, .ticket)
        XCTAssertEqual(refs?.first?.key, "LAZYAGENTS-286")
    }

    // MARK: - Send Modes & Harness Usage

    func testSendModeOrderIconsCyclingAndValidation() {
        XCTAssertEqual(ChatSendMode.runningModes, [.queue, .steer, .aside, .interrupt])
        XCTAssertEqual(ChatSendMode.runningModes.map(\.systemImage), ["clock", "safari", "arrow.triangle.branch", "bolt"])
        XCTAssertEqual(ChatSendMode.runningModes.map(\.actionLabel), ["Queue", "Steer", "Ask aside", "Interrupt"])
        XCTAssertEqual(ChatSendMode.runningModes.map(\.sendButtonSystemImage), ["arrow.up", "safari", "arrow.triangle.branch", "bolt"])

        // Forward and reverse Tab cycling across all 4 running modes
        XCTAssertEqual(ChatSendMode.queue.cycled(), .steer)
        XCTAssertEqual(ChatSendMode.steer.cycled(), .aside)
        XCTAssertEqual(ChatSendMode.aside.cycled(), .interrupt)
        XCTAssertEqual(ChatSendMode.interrupt.cycled(), .queue)
        XCTAssertEqual(ChatSendMode.queue.cycled(backward: true), .interrupt)
        XCTAssertEqual(ChatSendMode.steer.cycled(backward: true), .queue)
        XCTAssertEqual(ChatSendMode.send.cycled(), .queue)
        XCTAssertEqual(ChatSendMode.send.cycled(backward: true), .interrupt)

        // Placeholders reflect active mode and persona name
        XCTAssertTrue(ChatSendMode.queue.placeholder(personaName: "Meow").contains("Meow"))
        XCTAssertTrue(ChatSendMode.steer.placeholder(personaName: "Meow").contains("Steer Meow mid-turn"))
        XCTAssertTrue(ChatSendMode.aside.placeholder(personaName: "Meow").contains("Meow keeps working"))
        XCTAssertTrue(ChatSendMode.interrupt.placeholder(personaName: "Meow").contains("Stop Meow"))

        // Text-only validation allows send & interrupt with attachments/context/research, rejects queue/steer/aside
        XCTAssertNil(ChatComposerSendLogic.textOnlyValidationError(mode: .send, hasAttachments: true, hasContextChips: true, researchMode: true))
        XCTAssertNil(ChatComposerSendLogic.textOnlyValidationError(mode: .interrupt, hasAttachments: true, hasContextChips: true, researchMode: true))
        XCTAssertNil(ChatComposerSendLogic.textOnlyValidationError(mode: .queue, hasAttachments: false, hasContextChips: false, researchMode: false))
        XCTAssertNotNil(ChatComposerSendLogic.textOnlyValidationError(mode: .queue, hasAttachments: true, hasContextChips: false, researchMode: false))
        XCTAssertNotNil(ChatComposerSendLogic.textOnlyValidationError(mode: .steer, hasAttachments: false, hasContextChips: true, researchMode: false))
        XCTAssertNotNil(ChatComposerSendLogic.textOnlyValidationError(mode: .aside, hasAttachments: false, hasContextChips: false, researchMode: true))
    }

    func testSendModeResolutionAndHarnessUsageFormatting() {
        XCTAssertEqual(
            ChatComposerSendLogic.resolveSendMode(isRunning: false, preferredWhileRunning: .steer, parsedCommand: nil),
            .send
        )
        XCTAssertEqual(
            ChatComposerSendLogic.resolveSendMode(isRunning: true, preferredWhileRunning: .steer, parsedCommand: nil),
            .steer
        )
        XCTAssertEqual(
            ChatComposerSendLogic.resolveSendMode(isRunning: true, preferredWhileRunning: .interrupt, parsedCommand: nil),
            .interrupt
        )
        XCTAssertEqual(
            ChatComposerSendLogic.resolveSendMode(isRunning: true, preferredWhileRunning: .send, parsedCommand: nil),
            .queue
        )
        XCTAssertEqual(
            ChatComposerSendLogic.resolveSendMode(isRunning: false, preferredWhileRunning: .queue, parsedCommand: ChatParsedCommand(name: "aside", arg: "hi")),
            .aside
        )

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let activity = API.HarnessActivity(
            connected: true,
            harness: "claude-code",
            label: "Claude Code",
            limitedUntil: nil,
            plan: "max",
            running: 1,
            usageAvailable: true,
            usageCheckedAt: nil,
            usageChecking: false,
            windows: [
                API.UsageWindow(id: "five_hour", kind: .session, label: "Session", resetsAt: "2023-11-14T23:13:20Z", usedPercent: 84.4),
            ]
        )

        XCTAssertEqual(ChatHarnessUsageLogic.compactBadge(for: activity), "84%")
        let rows = ChatHarnessUsageLogic.railUsageRows(for: activity, now: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "Session")
        XCTAssertEqual(rows[0].value, "84%")
        XCTAssertEqual(rows[0].tone, .warn)
        XCTAssertEqual(rows[0].meta?.first, "Max")
    }

    // MARK: - Dictation Splicing

    func testDictationAnchorSplitsAndClampsCursor() {
        XCTAssertEqual(
            ChatComposerDictationLogic.anchor(in: "Hello world", cursorUTF16: 5),
            ChatDictationAnchor(prefix: "Hello", suffix: " world")
        )
        XCTAssertEqual(
            ChatComposerDictationLogic.anchor(in: "Hello", cursorUTF16: -4),
            ChatDictationAnchor(prefix: "", suffix: "Hello")
        )
        XCTAssertEqual(
            ChatComposerDictationLogic.anchor(in: "Hello", cursorUTF16: 99),
            ChatDictationAnchor(prefix: "Hello", suffix: "")
        )
    }

    func testDictationComposeHandlesEmptyAndSpacing() {
        let empty = ChatComposerDictationLogic.compose(
            anchor: ChatDictationAnchor(prefix: "", suffix: ""),
            spoken: "check the logs"
        )
        XCTAssertEqual(empty.text, "check the logs")
        XCTAssertEqual(empty.cursorUTF16, 14)

        let whitespaceOnly = ChatComposerDictationLogic.compose(
            anchor: ChatDictationAnchor(prefix: "Hi ", suffix: "there"),
            spoken: "   \n"
        )
        XCTAssertEqual(whitespaceOnly.text, "Hi there")
        XCTAssertEqual(whitespaceOnly.cursorUTF16, 3)

        let appendNoSpace = ChatComposerDictationLogic.compose(
            anchor: ChatDictationAnchor(prefix: "Hello", suffix: ""),
            spoken: "world"
        )
        XCTAssertEqual(appendNoSpace.text, "Hello world")
        XCTAssertEqual(appendNoSpace.cursorUTF16, 11)

        let appendWithSpace = ChatComposerDictationLogic.compose(
            anchor: ChatDictationAnchor(prefix: "Hello ", suffix: ""),
            spoken: "world"
        )
        XCTAssertEqual(appendWithSpace.text, "Hello world")
        XCTAssertEqual(appendWithSpace.cursorUTF16, 11)

        let midInsert = ChatComposerDictationLogic.compose(
            anchor: ChatDictationAnchor(prefix: "Ask", suffix: "about this"),
            spoken: "Judy"
        )
        XCTAssertEqual(midInsert.text, "Ask Judy about this")
        XCTAssertEqual(midInsert.cursorUTF16, 8)
    }

    func testPushToTalkReleaseDistinguishesHoldFromTap() {
        XCTAssertEqual(
            ChatComposerDictationLogic.releaseAction(elapsedSeconds: 0.12, wasListeningBeforePress: false),
            .keepListening
        )
        XCTAssertEqual(
            ChatComposerDictationLogic.releaseAction(elapsedSeconds: ChatComposerDictationLogic.holdThresholdSeconds, wasListeningBeforePress: false),
            .stopAndCommit
        )
        XCTAssertEqual(
            ChatComposerDictationLogic.releaseAction(elapsedSeconds: 0.75, wasListeningBeforePress: false),
            .stopAndCommit
        )
        XCTAssertEqual(
            ChatComposerDictationLogic.releaseAction(elapsedSeconds: 0.08, wasListeningBeforePress: true),
            .stopAndCommit
        )
    }

    func testOutlineSlashCommandIsRegistered() {
        XCTAssertTrue(ChatSlashCommand.all.contains(where: { $0.name == "outline" }))
        let parsed = ChatSlashCommandLogic.parseCommand("/outline")
        XCTAssertEqual(parsed?.name, "outline")
    }
}
