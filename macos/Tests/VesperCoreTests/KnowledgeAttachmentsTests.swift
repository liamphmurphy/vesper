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
}
