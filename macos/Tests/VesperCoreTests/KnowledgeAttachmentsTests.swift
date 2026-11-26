import Foundation
import Testing
@testable import VesperCore

@Suite("Knowledge Attachments & Media Embeds")
struct KnowledgeAttachmentsTests {
    @Test("KnowledgeEmbed classifies images, videos, audio, PDFs, and generic files")
    func embedMediaClassification() {
        let img = KnowledgeEmbed(
            ref: "![[attachment:1/photo.heic]]",
            kind: "file",
            title: "photo.heic",
            url: "/api/v1/knowledge/assets/1",
            contentType: "image/heic",
            available: true
        )
        #expect(img.isImageEmbed)
        #expect(!img.isVideoEmbed)
        #expect(!img.isAudioEmbed)
        #expect(!img.isPDFEmbed)
        #expect(img.hasInlinePreview)

        let vid = KnowledgeEmbed(
            ref: "![[attachment:2/demo.mov]]",
            kind: "file",
            title: "demo.mov",
            url: "/api/v1/knowledge/assets/2",
            contentType: "video/quicktime",
            available: true
        )
        #expect(vid.isVideoEmbed)
        #expect(!vid.isImageEmbed)
        #expect(!vid.isAudioEmbed)
        #expect(vid.hasInlinePreview)

        let aud = KnowledgeEmbed(
            ref: "![[attachment:3/memo.m4a]]",
            kind: "file",
            title: "memo.m4a",
            url: "/api/v1/knowledge/assets/3",
            contentType: "audio/mp4",
            available: true
        )
        #expect(aud.isAudioEmbed)
        #expect(!aud.isVideoEmbed)
        #expect(aud.hasInlinePreview)

        let pdf = KnowledgeEmbed(
            ref: "![[attachment:4/spec.pdf]]",
            kind: "file",
            title: "spec.pdf",
            url: "/api/v1/knowledge/assets/4",
            contentType: "application/pdf",
            available: true
        )
        #expect(pdf.isPDFEmbed)
        #expect(pdf.hasInlinePreview)

        let zip = KnowledgeEmbed(
            ref: "![[attachment:5/archive.zip]]",
            kind: "file",
            title: "archive.zip",
            url: "/api/v1/knowledge/assets/5",
            contentType: "application/zip",
            available: true
        )
        #expect(zip.isFileEmbed)
        #expect(!zip.isImageEmbed && !zip.isVideoEmbed && !zip.isAudioEmbed && !zip.isPDFEmbed)
        #expect(zip.hasInlinePreview)

        let unavailable = KnowledgeEmbed(
            ref: "![[attachment:6/missing.mp4]]",
            kind: "unresolved",
            title: "missing.mp4",
            url: nil,
            contentType: "video/mp4",
            available: false
        )
        #expect(!unavailable.hasInlinePreview)
    }

    @Test("Uploaded asset converts directly into a resolvable inline KnowledgeEmbed")
    func uploadedAssetToEmbed() {
        let uploaded = KnowledgeUploadedAsset(
            id: "abc",
            ref: "attachment:abc/clip.mp4",
            url: "/api/v1/knowledge/assets/abc",
            filename: "clip.mp4",
            path: "attachments/clip.mp4",
            contentType: "video/mp4",
            sizeBytes: 2048
        )
        let embed = uploaded.asKnowledgeEmbed()
        #expect(embed.ref == "![[attachment:abc/clip.mp4]]")
        #expect(embed.title == "clip.mp4")
        #expect(embed.isVideoEmbed)
        #expect(embed.hasInlinePreview)
    }

    @Test("buildTree places attachments in a top-level attachments folder and flattenTree emits attachment rows")
    func attachmentsFolderTree() {
        let pages = [
            KnowledgePageRow(id: "p1", title: "Welcome", path: "Inbox/Welcome"),
            KnowledgePageRow(id: "p2", title: "Notes", path: "Projects/Notes"),
        ]
        let attachments = [
            KnowledgeAttachment(
                id: "a2",
                filename: "zeta.pdf",
                ref: "attachment:a2/zeta.pdf",
                url: "/api/v1/knowledge/assets/a2",
                contentType: "application/pdf",
                sizeBytes: 512
            ),
            KnowledgeAttachment(
                id: "a1",
                filename: "alpha.png",
                ref: "attachment:a1/alpha.png",
                url: "/api/v1/knowledge/assets/a1",
                contentType: "image/png",
                sizeBytes: 1024
            ),
        ]

        let tree = KnowledgeShellLogic.buildTree(from: pages, attachments: attachments)
        let folderNames = tree.folders.map(\.name)
        #expect(folderNames == ["Inbox", "attachments", "Projects"])
        let attFolder = tree.folders.first { $0.path == "attachments" }
        #expect(attFolder?.count == 2)
        #expect(attFolder?.attachments.map(\.filename) == ["alpha.png", "zeta.pdf"])

        let flat = KnowledgeShellLogic.flattenTree(tree, expanded: ["attachments"])
        let attRows = flat.compactMap { row -> KnowledgeAttachment? in
            if case .attachment(let att) = row.kind { return att }
            return nil
        }
        #expect(attRows.map(\.id) == ["a1", "a2"])

        // When no attachments exist, no empty attachments folder is created.
        let emptyTree = KnowledgeShellLogic.buildTree(from: pages, attachments: [])
        #expect(!emptyTree.folders.contains { $0.path == "attachments" })
    }

    @Test("Attachment route resolves to .attachment destination and filterAttachments narrows by filename/type")
    func attachmentRouteAndFilter() {
        let match = NativeRouteRegistry.standard(debug: false).resolve("/knowledge/attachments/asset-42")
        #expect(match != nil)
        if let match {
            #expect(KnowledgeShellLogic.destination(for: match) == .attachment(id: "asset-42"))
        }

        let items = [
            KnowledgeAttachment(id: "1", filename: "recording.m4a", ref: "r1", url: "/u1", contentType: "audio/mp4"),
            KnowledgeAttachment(id: "2", filename: "diagram.png", ref: "r2", url: "/u2", contentType: "image/png"),
        ]
        #expect(KnowledgeShellLogic.filterAttachments(items, matching: "audio").map(\.id) == ["1"])
        #expect(KnowledgeShellLogic.filterAttachments(items, matching: "DIAGRAM").map(\.id) == ["2"])
        #expect(KnowledgeShellLogic.markdownEmbedBlock(for: ["attachment:1/a.png", "attachment:2/b.mp4"]) == "![[attachment:1/a.png]]\n![[attachment:2/b.mp4]]")
    }

    @Test("removingEmbed cleanly strips standalone PDF/image lines, collapses redundant blank lines, and supports Undo")
    func removingStandaloneInlineEmbeds() throws {
        let pdfRef = "![[attachment:4/spec.pdf]]"
        let pdfEmbed = KnowledgeEmbed(
            ref: pdfRef,
            kind: "file",
            title: "spec.pdf",
            url: "/api/v1/knowledge/assets/4",
            contentType: "application/pdf",
            available: true
        )

        // 1. Sole embed in note (no newline & with trailing newline).
        for single in [pdfRef, "\(pdfRef)\n"] {
            let placement = try #require(KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: single, embeds: [pdfEmbed]).first)
            let edit = try #require(KnowledgeMarkdownSyntax.removingEmbed(placement, in: single))
            #expect(edit.resultingText == "")
            #expect(edit.caretUTF16 == 0)
        }

        // 2. Pasted directly after a paragraph with trailing newline (exact inverse of paste insertion).
        let pastedAfter = "Intro\n\(pdfRef)\n"
        let p2 = try #require(KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: pastedAfter, embeds: [pdfEmbed]).first)
        let e2 = try #require(KnowledgeMarkdownSyntax.removingEmbed(p2, in: pastedAfter))
        #expect(e2.resultingText == "Intro\n")
        #expect(e2.caretUTF16 == 6)

        // 3. Trailing line without trailing newline consumes the preceding newline cleanly.
        let trailingNoNL = "Intro\n\(pdfRef)"
        let p3 = try #require(KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: trailingNoNL, embeds: [pdfEmbed]).first)
        let e3 = try #require(KnowledgeMarkdownSyntax.removingEmbed(p3, in: trailingNoNL))
        #expect(e3.resultingText == "Intro")
        #expect(e3.caretUTF16 == 5)

        // 4. Standalone embed between blank lines collapses redundant blank line.
        let sandwiched = "Intro\n\n\(pdfRef)\n\nNext paragraph"
        let p4 = try #require(KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: sandwiched, embeds: [pdfEmbed]).first)
        let e4 = try #require(KnowledgeMarkdownSyntax.removingEmbed(p4, in: sandwiched))
        #expect(e4.resultingText == "Intro\n\nNext paragraph")
        #expect(e4.caretUTF16 == 7)

        // 5. Same behavior with CRLF line endings.
        let crlfSandwiched = "Intro\r\n\r\n\(pdfRef)\r\n\r\nNext"
        let p5 = try #require(KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: crlfSandwiched, embeds: [pdfEmbed]).first)
        let e5 = try #require(KnowledgeMarkdownSyntax.removingEmbed(p5, in: crlfSandwiched))
        #expect(e5.resultingText == "Intro\r\n\r\nNext")

        // 6. Applying via KnowledgeEditorDocument.replaceProse supports exact Undo/Redo round-trip.
        var doc = KnowledgeEditorDocument(markdown: sandwiched)
        let changed = doc.replaceProse(
            in: 0,
            range: e4.replacementRange,
            with: e4.replacement,
            newSelection: DocumentSelection(collapsedAt: .prose(segmentIndex: 0, utf16Offset: e4.caretUTF16))
        )
        #expect(changed)
        #expect(doc.serialize() == "Intro\n\nNext paragraph")
        let undone = doc.undo()
        #expect(undone)
        #expect(doc.serialize() == sandwiched)
        let redone = doc.redo()
        #expect(redone)
        #expect(doc.serialize() == "Intro\n\nNext paragraph")
    }

    @Test("removingEmbed preserves sibling embeds, tidies inline spacing, handles resized/duplicate embeds, and guards out-of-bounds")
    func removingInlineAndSharedLineEmbeds() throws {
        let imgRef = "![[attachment:1/photo.png]]"
        let pdfRef = "![[attachment:2/spec.pdf]]"
        let embeds = [
            KnowledgeEmbed(ref: imgRef, kind: "file", title: "photo.png", url: "/api/v1/knowledge/assets/1", contentType: "image/png", available: true),
            KnowledgeEmbed(ref: pdfRef, kind: "file", title: "spec.pdf", url: "/api/v1/knowledge/assets/2", contentType: "application/pdf", available: true),
        ]

        // 1. Two embeds on the same standalone line: removing one keeps the sibling intact.
        let sharedLine = "\(imgRef) \(pdfRef)\n"
        let sharedPlacements = KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: sharedLine, embeds: embeds)
        #expect(sharedPlacements.count == 2)
        let removeFirst = try #require(KnowledgeMarkdownSyntax.removingEmbed(sharedPlacements[0], in: sharedLine))
        #expect(removeFirst.resultingText == "\(pdfRef)\n")
        let removeSecond = try #require(KnowledgeMarkdownSyntax.removingEmbed(sharedPlacements[1], in: sharedLine))
        #expect(removeSecond.resultingText == "\(imgRef)\n")

        // 2. Inline inside prose sentence (middle, start, end).
        let midSentence = "See \(pdfRef) here."
        let midP = try #require(KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: midSentence, embeds: embeds).first)
        #expect(KnowledgeMarkdownSyntax.removingEmbed(midP, in: midSentence)?.resultingText == "See here.")

        let startSentence = "\(pdfRef) is attached"
        let startP = try #require(KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: startSentence, embeds: embeds).first)
        #expect(KnowledgeMarkdownSyntax.removingEmbed(startP, in: startSentence)?.resultingText == "is attached")

        let endSentence = "See \(pdfRef)"
        let endP = try #require(KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: endSentence, embeds: embeds).first)
        #expect(KnowledgeMarkdownSyntax.removingEmbed(endP, in: endSentence)?.resultingText == "See")

        // 3. Duplicate occurrences: removing the second leaves the first untouched.
        let duplicated = "First:\n\(pdfRef)\n\nSecond:\n\(pdfRef)\n"
        let dupPlacements = KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: duplicated, embeds: embeds)
        #expect(dupPlacements.count == 2)
        let removeSecondDup = try #require(KnowledgeMarkdownSyntax.removingEmbed(dupPlacements[1], in: duplicated))
        #expect(removeSecondDup.resultingText == "First:\n\(pdfRef)\n\nSecond:\n")

        // 4. Resized image embed token (`|420`) removes cleanly.
        let resized = "Before\n![[attachment:1/photo.png|420]]\nAfter"
        let resizedP = try #require(KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: resized, embeds: embeds).first)
        #expect(KnowledgeMarkdownSyntax.removingEmbed(resizedP, in: resized)?.resultingText == "Before\nAfter")

        // 5. Out-of-bounds placement against shorter text returns nil safely.
        #expect(KnowledgeMarkdownSyntax.removingEmbed(dupPlacements[1], in: "short") == nil)
    }
}
