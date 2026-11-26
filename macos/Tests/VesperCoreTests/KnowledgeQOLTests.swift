import CoreGraphics
import Foundation
import Testing
@testable import VesperCore

@Suite("Knowledge QOL Logic")
struct KnowledgeQOLTests {

    // MARK: - 1. Attachment Usage, Management APIs & Sidebar Drag Payloads

    @Test("KnowledgeAttachment decodes usage counts, referencing docs, and ownership")
    func attachmentUsageDecoding() throws {
        let json = """
        {
          "folder": "attachments",
          "attachments": [
            {
              "id": "a1",
              "filename": "diagram.png",
              "title": "diagram.png",
              "path": "attachments/diagram.png",
              "ref": "attachment:a1/diagram.png",
              "url": "/api/v1/knowledge/assets/a1",
              "content_type": "image/png",
              "size_bytes": 4096,
              "created_at": "2026-11-26T00:00:00Z",
              "usage_count": 2,
              "used_in": [
                {"id": "p1", "title": "Architecture", "path": "Specs/Architecture"},
                {"id": "p2", "title": "Overview", "path": "Overview"}
              ],
              "is_owner": true
            },
            {
              "id": "a2",
              "filename": "old.pdf",
              "title": "old.pdf",
              "path": "attachments/old.pdf",
              "ref": "attachment:a2/old.pdf",
              "url": "/api/v1/knowledge/assets/a2",
              "content_type": "application/pdf",
              "size_bytes": 1024,
              "created_at": "2026-11-26T00:00:00Z",
              "usage_count": 0,
              "used_in": [],
              "is_owner": false
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(KnowledgeAttachmentsResponse.self, from: Data(json.utf8))
        #expect(decoded.attachments.count == 2)

        let first = decoded.attachments[0]
        #expect(first.usageCount == 2)
        #expect(!first.isOrphaned)
        #expect(first.usageSummary == "Used in 2 docs")
        #expect(first.usedIn.map(\.id) == ["p1", "p2"])
        #expect(first.isOwner)

        let second = decoded.attachments[1]
        #expect(second.usageCount == 0)
        #expect(second.isOrphaned)
        #expect(second.usageSummary == "Orphaned")
        #expect(!second.isOwner)
    }

    @Test("Attachment rename/delete and headings API endpoints build expected paths")
    func attachmentAndHeadingRequests() {
        let rename = KnowledgeAPI.renameAttachment(id: "att-1", filename: "new.png")
        #expect(rename.method == "PATCH")
        #expect(rename.path == "/api/v1/knowledge/attachments/att-1")

        let del = KnowledgeAPI.deleteAttachment(id: "att-1")
        #expect(del.method == "DELETE")
        #expect(del.path == "/api/v1/knowledge/attachments/att-1")

        let headings = KnowledgeAPI.listHeadings(q: "ambush", includeAgent: true)
        #expect(headings.method == "GET")
        #expect(headings.path == "/api/v1/knowledge/headings")
        #expect(headings.pathAndQuery.contains("q=ambush"))
        #expect(headings.pathAndQuery.contains("include_agent=true"))
    }

    @Test("buildTree includes empty attachments folder when requested and sidebar drags format links/embeds")
    func sidebarAttachmentsDropAndDrag() {
        let pages = [KnowledgePageRow(id: "p1", title: "Session 1", path: "DnD/Session 1")]
        let emptyIncluded = KnowledgeShellLogic.buildTree(
            from: pages,
            attachments: [],
            includeEmptyAttachmentsFolder: true
        )
        #expect(emptyIncluded.folders.contains { $0.path == "attachments" && $0.count == 0 })

        let pageDrag = KnowledgeDragItem.page(pages[0])
        let decodedPage = KnowledgeDragItem.decodeDragPayload(pageDrag.encodeDragPayload())
        #expect(decodedPage == pageDrag)
        #expect(KnowledgeShellLogic.droppedMarkdown(for: pageDrag, optionHeld: false) == "[[DnD/Session 1]]")
        #expect(KnowledgeShellLogic.droppedMarkdown(for: pageDrag, optionHeld: true) == "![[DnD/Session 1]]")

        let att = KnowledgeAttachment(
            id: "a1",
            filename: "map.png",
            ref: "attachment:a1/map.png",
            url: "/api/v1/knowledge/assets/a1",
            contentType: "image/png"
        )
        let attDrag = KnowledgeDragItem.attachment(att)
        let decodedAtt = KnowledgeDragItem.decodeDragPayload(attDrag.encodeDragPayload())
        #expect(decodedAtt == attDrag)
        #expect(KnowledgeShellLogic.droppedMarkdown(for: attDrag, optionHeld: false) == "![[attachment:a1/map.png]]")
        #expect(attDrag.asKnowledgeEmbed()?.isImageEmbed == true)
        #expect(KnowledgeShellLogic.planDrop(item: attDrag, ontoFolder: "DnD", expanded: []) == nil)

        let folderDrag = KnowledgeDragItem.folder(KnowledgeTreeFolder(name: "DnD", path: "DnD"))
        #expect(KnowledgeShellLogic.droppedMarkdown(for: folderDrag, optionHeld: false) == nil)
    }

    // MARK: - 2. Paste URL over Selected Text & Screenshot Filename

    @Test("pasteURLOverSelection wraps selected phrase into Markdown link and skips invalid cases")
    func pasteURLOverSelectionCases() {
        let res = KnowledgeMarkdownFormatting.pasteURLOverSelection(
            text: "Check the release notes for details",
            selection: NSRange(location: 10, length: 13),
            pastedString: "  https://example.com/releases  "
        )
        #expect(res?.text == "Check the [release notes](https://example.com/releases) for details")
        #expect(res?.selection == NSRange(location: 55, length: 0))

        // Collapsed selection does not wrap.
        #expect(KnowledgeMarkdownFormatting.pasteURLOverSelection(
            text: "hello",
            selection: NSRange(location: 2, length: 0),
            pastedString: "https://example.com"
        ) == nil)

        // Non-URL paste does not wrap.
        #expect(KnowledgeMarkdownFormatting.pasteURLOverSelection(
            text: "hello world",
            selection: NSRange(location: 0, length: 5),
            pastedString: "not a url"
        ) == nil)

        // Pasting a URL over an existing URL replaces normally rather than double-wrapping.
        #expect(KnowledgeMarkdownFormatting.pasteURLOverSelection(
            text: "https://old.example.com",
            selection: NSRange(location: 0, length: 23),
            pastedString: "https://new.example.com"
        ) == nil)

        // Inside inline code does not wrap.
        #expect(KnowledgeMarkdownFormatting.pasteURLOverSelection(
            text: "Run `my tool` now",
            selection: NSRange(location: 5, length: 7),
            pastedString: "https://example.com"
        ) == nil)

        // Screenshot filename is deterministic and filesystem-safe.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_764_137_705) // 2025-11-26 06:15:05 UTC
        let filename = KnowledgeMarkdownFormatting.screenshotFilename(date: date, extension: "PNG", calendar: cal)
        #expect(filename == "Screenshot-2025-11-26-061505.png")
    }

    // MARK: - 3. Smart List / Checklist & Auto-Pair Editing

    @Test("Smart Enter continues checklists, bullets, and numbered lists, and exits empty items")
    func smartNewlineLists() {
        // Checklist (checked item continues as unchecked).
        let check1 = KnowledgeSmartEditing.handleNewline(
            in: "  - [x] Ship PR",
            selection: NSRange(location: 15, length: 0)
        )
        #expect(check1?.text == "  - [x] Ship PR\n  - [ ] ")
        #expect(check1?.selection == NSRange(location: 24, length: 0))

        // Exiting an empty checklist line clears the empty prefix.
        let checkExit = KnowledgeSmartEditing.handleNewline(
            in: "- [ ] First\n- [ ] ",
            selection: NSRange(location: 18, length: 0)
        )
        #expect(checkExit?.text == "- [ ] First\n")
        #expect(checkExit?.selection == NSRange(location: 12, length: 0))

        // Unordered bullet splits mid-line cleanly.
        let bulletSplit = KnowledgeSmartEditing.handleNewline(
            in: "- hello world",
            selection: NSRange(location: 7, length: 0)
        )
        #expect(bulletSplit?.text == "- hello\n-  world")
        #expect(bulletSplit?.selection == NSRange(location: 10, length: 0))

        // Numbered list increments automatically.
        let ordered = KnowledgeSmartEditing.handleNewline(
            in: "2. Second step",
            selection: NSRange(location: 14, length: 0)
        )
        #expect(ordered?.text == "2. Second step\n3. ")
        #expect(ordered?.selection == NSRange(location: 18, length: 0))

        // Plain prose returns nil.
        #expect(KnowledgeSmartEditing.handleNewline(in: "Just prose", selection: NSRange(location: 10, length: 0)) == nil)

        // Inside fenced code block returns nil.
        let fenced = "```md\n- item\n```"
        #expect(KnowledgeSmartEditing.handleNewline(in: fenced, selection: NSRange(location: 12, length: 0)) == nil)
    }

    @Test("Smart Tab and Shift+Tab indent and outdent single list items and multi-line selections")
    func smartTabIndentOutdent() {
        let indented = KnowledgeSmartEditing.handleTab(
            in: "- [ ] Task",
            selection: NSRange(location: 10, length: 0),
            outdent: false
        )
        #expect(indented?.text == "  - [ ] Task")
        #expect(indented?.selection == NSRange(location: 12, length: 0))

        let outdented = KnowledgeSmartEditing.handleTab(
            in: "  - [ ] Task",
            selection: NSRange(location: 12, length: 0),
            outdent: true
        )
        #expect(outdented?.text == "- [ ] Task")
        #expect(outdented?.selection == NSRange(location: 10, length: 0))

        // Multi-line selection indents and outdents every spanned line.
        let multi = "- a\n- b\n- c"
        let multiIndent = KnowledgeSmartEditing.handleTab(
            in: multi,
            selection: NSRange(location: 0, length: 7),
            outdent: false
        )
        #expect(multiIndent?.text == "  - a\n  - b\n- c")
        #expect(multiIndent?.selection == NSRange(location: 2, length: 9))

        // Single-line plain prose Tab falls through (nil).
        #expect(KnowledgeSmartEditing.handleTab(in: "plain text", selection: NSRange(location: 5, length: 0), outdent: false) == nil)
    }

    @Test("Auto-pair closes [[, `, and **, handles triple backticks for fences, skips closing delimiters, and pairs backspace")
    func smartAutoPairEditing() {
        // Typing 2nd `[` closes `[[|]]`.
        let wiki = KnowledgeSmartEditing.handleTypedText("[", in: "See [", selection: NSRange(location: 5, length: 0))
        #expect(wiki?.text == "See [[]]")
        #expect(wiki?.selection == NSRange(location: 6, length: 0))

        // Typing `]` skips over closing `]`.
        let skipBracket = KnowledgeSmartEditing.handleTypedText("]", in: "See [[Note]]", selection: NSRange(location: 10, length: 0))
        #expect(skipBracket?.text == "See [[Note]]")
        #expect(skipBracket?.selection == NSRange(location: 11, length: 0))

        // Typing backtick auto-closes `` `|` ``; typing 2nd backtick skips over; typing 3rd builds ``` cleanly!
        let tick1 = KnowledgeSmartEditing.handleTypedText("`", in: "", selection: NSRange(location: 0, length: 0))
        #expect(tick1?.text == "``")
        #expect(tick1?.selection == NSRange(location: 1, length: 0))

        let tick2 = KnowledgeSmartEditing.handleTypedText("`", in: tick1!.text, selection: tick1!.selection)
        #expect(tick2?.text == "``")
        #expect(tick2?.selection == NSRange(location: 2, length: 0))

        let tick3 = KnowledgeSmartEditing.handleTypedText("`", in: tick2!.text, selection: tick2!.selection)
        #expect(tick3 == nil) // falls through to normal insert -> "```"

        // Typing 2nd `*` closes `**|**` and typing `*` before `**` skips over.
        let bold = KnowledgeSmartEditing.handleTypedText("*", in: "hello *", selection: NSRange(location: 7, length: 0))
        #expect(bold?.text == "hello ****")
        #expect(bold?.selection == NSRange(location: 8, length: 0))

        let skipBold = KnowledgeSmartEditing.handleTypedText("*", in: "hello **world**", selection: NSRange(location: 13, length: 0))
        #expect(skipBold?.text == "hello **world**")
        #expect(skipBold?.selection == NSRange(location: 14, length: 0))

        // Selection wrapping.
        let wrapCode = KnowledgeSmartEditing.handleTypedText("`", in: "run cmd now", selection: NSRange(location: 4, length: 3))
        #expect(wrapCode?.text == "run `cmd` now")
        #expect(wrapCode?.selection == NSRange(location: 5, length: 3))

        // Paired Backspace deletes matched empty delimiters.
        let bsWiki = KnowledgeSmartEditing.handleBackspace(in: "See [[]]", selection: NSRange(location: 6, length: 0))
        #expect(bsWiki?.text == "See [")
        #expect(bsWiki?.selection == NSRange(location: 5, length: 0))

        let bsTick = KnowledgeSmartEditing.handleBackspace(in: "a `` b", selection: NSRange(location: 3, length: 0))
        #expect(bsTick?.text == "a  b")
        #expect(bsTick?.selection == NSRange(location: 2, length: 0))

        let bsBold = KnowledgeSmartEditing.handleBackspace(in: "****", selection: NSRange(location: 2, length: 0))
        #expect(bsBold?.text == "*")
        #expect(bsBold?.selection == NSRange(location: 1, length: 0))
    }

    // MARK: - 4. Obsidian Image Dimensions & Resize Rewriting

    @Test("Obsidian embed dimensions parse, rewrite, size, and keep inline embed identity stable")
    func embedDimensionsAndResizing() {
        #expect(KnowledgeEmbedDimensions.parse("400") == KnowledgeEmbedDimensions(width: 400, height: nil))
        #expect(KnowledgeEmbedDimensions.parse("400x260") == KnowledgeEmbedDimensions(width: 400, height: 260))
        #expect(KnowledgeEmbedDimensions.parse("caption") == nil)

        let target = KnowledgeMarkdownSyntax.parseWikiTarget(raw: "![[attachment:a1/shot.png|400]]")
        #expect(target?.embedDimensions == KnowledgeEmbedDimensions(width: 400, height: nil))
        #expect(target?.displayLabel(resolvedTitle: "shot.png") == "shot.png")

        let captioned = KnowledgeMarkdownSyntax.parseWikiTarget(raw: "![[attachment:a1/shot.png|Hero Shot|320]]")
        #expect(captioned?.embedDimensions == KnowledgeEmbedDimensions(width: 320, height: nil))
        #expect(captioned?.displayLabel(resolvedTitle: "shot.png") == "Hero Shot")

        #expect(KnowledgeMarkdownSyntax.updatingEmbedWidth(in: "![[attachment:a1/shot.png]]", width: 380) == "![[attachment:a1/shot.png|380]]")
        #expect(KnowledgeMarkdownSyntax.updatingEmbedWidth(in: "![[attachment:a1/shot.png|380]]", width: 520) == "![[attachment:a1/shot.png|520]]")
        #expect(KnowledgeMarkdownSyntax.updatingEmbedWidth(in: "![[attachment:a1/shot.png|Hero|380]]", width: 520) == "![[attachment:a1/shot.png|Hero|520]]")
        #expect(KnowledgeMarkdownSyntax.updatingEmbedWidth(in: "![[attachment:a1/shot.png|520]]", width: nil) == "![[attachment:a1/shot.png]]")

        // Fitted size respects explicit width up to container width and preserves aspect ratio.
        let explicitSize = KnowledgeMarkdownSyntax.fittedInlineImageSize(
            naturalSize: CGSize(width: 2400, height: 1200),
            maxWidth: 460,
            maxHeight: 320,
            explicitDimensions: KnowledgeEmbedDimensions(width: 600),
            containerMaxWidth: 700
        )
        #expect(explicitSize == CGSize(width: 600, height: 300))

        // Resizing in markdown before save still matches the previously resolved embed and keeps groupID stable.
        let embed = KnowledgeEmbed(
            ref: "![[attachment:a1/shot.png]]",
            kind: "file",
            title: "shot.png",
            url: "/api/v1/knowledge/assets/a1",
            contentType: "image/png",
            available: true
        )
        let beforeGroups = KnowledgeMarkdownSyntax.groupInlineEmbedsByParagraph(
            in: "![[attachment:a1/shot.png]]",
            embeds: [embed]
        )
        let afterGroups = KnowledgeMarkdownSyntax.groupInlineEmbedsByParagraph(
            in: "![[attachment:a1/shot.png|360]]",
            embeds: [embed]
        )
        #expect(afterGroups.count == 1)
        #expect(afterGroups[0].id == beforeGroups[0].id)
        #expect(afterGroups[0].placements[0].target.embedDimensions == KnowledgeEmbedDimensions(width: 360))
    }

    // MARK: - 5. All-Type ![[ Completion & Quick Switcher

    @Test("![[ completion matches attachments across all media types including MIME/type detail")
    func embedCompletionAllTypes() {
        let trigger = KnowledgeCompletionLogic.matchTrigger(in: "![[pdf", caretUTF16: 6)!
        let candidates = [
            KnowledgeCompletionCandidate(kind: .embed, title: "photo.png", insertRef: "attachment:1/photo.png", detail: "Image · attachments/photo.png", symbolName: "photo"),
            KnowledgeCompletionCandidate(kind: .embed, title: "spec.pdf", insertRef: "attachment:2/spec.pdf", detail: "PDF · attachments/spec.pdf", symbolName: "doc.richtext"),
            KnowledgeCompletionCandidate(kind: .embed, title: "demo.mp4", insertRef: "attachment:3/demo.mp4", detail: "Video · attachments/demo.mp4", symbolName: "film"),
        ]
        let ranked = KnowledgeCompletionLogic.rankCandidates(candidates, for: trigger)
        #expect(ranked.map(\.title) == ["spec.pdf"])
        #expect(ranked[0].symbolName == "doc.richtext")
    }

    @Test("Quick Switcher fuzzy-searches docs, live & vault headings, and attachments with prefix filters")
    func quickSwitcherSearch() {
        let pages = [
            KnowledgePageRow(id: "p1", title: "Campaign Notes", path: "DnD/Campaign Notes", properties: ["tags": .array([.string("dnd")])]),
            KnowledgePageRow(id: "p2", title: "Release Checklist", path: "Work/Release Checklist"),
        ]
        let attachments = [
            KnowledgeAttachment(id: "a1", filename: "tavern-map.png", ref: "attachment:a1/tavern-map.png", url: "/u/a1", contentType: "image/png", usageCount: 1),
            KnowledgeAttachment(id: "a2", filename: "session-audio.m4a", ref: "attachment:a2/session-audio.m4a", url: "/u/a2", contentType: "audio/mp4", usageCount: 0),
        ]
        let liveHeadings = [
            KnowledgeOutlineHeading(index: 0, level: 2, text: "Tavern Ambush", segmentIndex: 0, utf16Location: 0, utf16Length: 16),
        ]
        let vaultHeadings = [
            // Stale server copy of open page p1 should be deduped against liveHeadings.
            KnowledgeHeadingRow(pageId: "p1", pageTitle: "Campaign Notes", pagePath: "DnD/Campaign Notes", level: 2, anchor: "tavern-ambush", heading: "Tavern Ambush", position: 1),
            KnowledgeHeadingRow(pageId: "p2", pageTitle: "Release Checklist", pagePath: "Work/Release Checklist", level: 2, anchor: "rollback-plan", heading: "Rollback Plan", position: 1),
        ]

        // Searching "tavern" finds live heading AND attachment, without duplicating p1's stale vault heading.
        let tavernHits = KnowledgeQuickSwitcherLogic.search(
            query: "tavern",
            pages: pages,
            attachments: attachments,
            vaultHeadings: vaultHeadings,
            currentPageId: "p1",
            currentPageTitle: "Campaign Notes",
            currentHeadings: liveHeadings
        )
        #expect(tavernHits.count == 2)
        #expect(tavernHits.contains { if case .currentHeading = $0.target { return true }; return false })
        #expect(tavernHits.contains { if case .attachment(let a) = $0.target { return a.id == "a1" }; return false })

        // `#` prefix narrows to headings only (both live and cross-doc).
        let headingOnly = KnowledgeQuickSwitcherLogic.search(
            query: "#roll",
            pages: pages,
            attachments: attachments,
            vaultHeadings: vaultHeadings,
            currentPageId: "p1",
            currentPageTitle: "Campaign Notes",
            currentHeadings: liveHeadings
        )
        #expect(headingOnly.count == 1)
        if case .vaultHeading(let row) = headingOnly[0].target {
            #expect(row.heading == "Rollback Plan")
            #expect(row.pageId == "p2")
        } else {
            Issue.record("Expected vaultHeading target")
        }

        // `!` prefix narrows to attachments only.
        let attOnly = KnowledgeQuickSwitcherLogic.search(
            query: "!audio",
            pages: pages,
            attachments: attachments,
            vaultHeadings: vaultHeadings
        )
        #expect(attOnly.count == 1)
        if case .attachment(let a) = attOnly[0].target {
            #expect(a.id == "a2")
            #expect(attOnly[0].badge == "Unused")
        } else {
            Issue.record("Expected attachment target")
        }
    }
}
