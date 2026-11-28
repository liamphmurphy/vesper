import XCTest
@testable import VesperCore

final class ChatPromptTemplateTests: XCTestCase {
    private func makeTemplate(
        id: String,
        slug: String,
        title: String,
        body: String,
        personaId: String? = nil,
        spaceId: String? = nil
    ) -> API.PromptTemplate {
        API.PromptTemplate(
            body: body,
            createdAt: "2026-11-28T00:00:00Z",
            description: "",
            id: id,
            personaId: personaId.map { .value($0) },
            slug: slug,
            spaceId: spaceId.map { .value($0) },
            title: title,
            updatedAt: "2026-11-28T00:00:00Z"
        )
    }

    func testNormalizeSlugStripsPrefixesAndInvalidChars() {
        XCTAssertEqual(ChatPromptTemplateLogic.normalizeSlug("/Code Review!"), "code-review")
        XCTAssertEqual(ChatPromptTemplateLogic.normalizeSlug("#123_my_macro"), "my-macro")
        XCTAssertEqual(ChatPromptTemplateLogic.normalizeSlug("  TL;DR  "), "tl-dr")
    }

    func testApplicableTemplatesPreferMostSpecificScope() {
        let templates = [
            makeTemplate(id: "1", slug: "review", title: "Global Review", body: "global"),
            makeTemplate(id: "2", slug: "review", title: "Judy Review", body: "judy", personaId: "p-judy"),
            makeTemplate(id: "3", slug: "review", title: "Space Review", body: "space", spaceId: "s-vesper"),
            makeTemplate(id: "4", slug: "other", title: "Iris Only", body: "iris", personaId: "p-iris"),
        ]

        let forJudyInVesper = ChatPromptTemplateLogic.applicableTemplates(
            templates,
            personaId: "p-judy",
            spaceId: "s-vesper"
        )
        XCTAssertEqual(forJudyInVesper.map(\.id), ["3"])

        let forJudyOutsideSpace = ChatPromptTemplateLogic.applicableTemplates(
            templates,
            personaId: "p-judy",
            spaceId: nil
        )
        XCTAssertEqual(forJudyOutsideSpace.map(\.id), ["2"])
    }

    func testExpandSubstitutesInputAndClipboardAndAppendsTrailingInput() {
        let expanded = ChatPromptTemplateLogic.expand(
            body: "Review {{ clipboard }} focusing on {{input}}",
            input: "race conditions",
            clipboard: "func foo() {}"
        )
        XCTAssertEqual(expanded, "Review func foo() {} focusing on race conditions")

        let appended = ChatPromptTemplateLogic.expand(
            body: "Explain this concisely:",
            input: "Raft consensus",
            clipboard: nil
        )
        XCTAssertEqual(appended, "Explain this concisely:\n\nRaft consensus")
    }

    func testHashTriggerParsingAndMenuQuery() {
        XCTAssertEqual(ChatPromptTemplateLogic.hashMenuQuery(for: "#rev"), "rev")
        XCTAssertNil(ChatPromptTemplateLogic.hashMenuQuery(for: "## heading"))
        XCTAssertNil(ChatPromptTemplateLogic.hashMenuQuery(for: "#rev arg"))

        let parsed = ChatPromptTemplateLogic.parseHashTrigger("#review check locks")
        XCTAssertEqual(parsed, ChatParsedCommand(name: "review", arg: "check locks"))
    }
}
