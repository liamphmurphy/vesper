import XCTest
@testable import VesperCore

final class AppsAndSetupLogicTests: XCTestCase {
    func testSlugifyAndValidateSlug() {
        XCTAssertEqual(AppsHomeLogic.slugify("  My Finance App! "), "my-finance-app")
        XCTAssertNil(AppsHomeLogic.validateSlug("finance-2026"))
        XCTAssertNotNil(AppsHomeLogic.validateSlug(""))
        XCTAssertNotNil(AppsHomeLogic.validateSlug("-bad"))
        XCTAssertNotNil(AppsHomeLogic.validateSlug("UpperCase"))
        XCTAssertEqual(AppsHomeLogic.validateSlug("slides"), "\"slides\" is a reserved Vesper route.")
        XCTAssertEqual(AppsHomeLogic.validateSlug("docs"), "\"docs\" is a reserved Vesper route.")
        XCTAssertEqual(AppsHomeLogic.resolveIcon("bolt"), "bolt")
        XCTAssertEqual(AppsHomeLogic.resolveIcon("unknown"), "dashboard")
    }

    func testAppsRedirects() {
        XCTAssertEqual(AppsHomeLogic.knowledgeRedirectPath(for: "/apps/docs"), "/knowledge?kind=document")
        XCTAssertEqual(AppsHomeLogic.knowledgeRedirectPath(for: "/apps/slides"), "/knowledge?kind=deck")
        XCTAssertEqual(AppsHomeLogic.knowledgeRedirectPath(for: "/apps/designs"), "/knowledge?kind=design")
        XCTAssertNil(AppsHomeLogic.knowledgeRedirectPath(for: "/apps/finance"))
    }

    func testLandingAndProfileSetupHelpers() {
        XCTAssertTrue(LandingLogic.needsProfileSetup(name: "Local user", email: "me@example.com"))
        XCTAssertTrue(LandingLogic.needsProfileSetup(name: "Liam", email: "me@localhost"))
        XCTAssertFalse(LandingLogic.needsProfileSetup(name: "Liam", email: "liam@example.com"))

        let onboarded = API.User(
            email: "liam@example.com",
            harnessConnected: true,
            id: "u1",
            initials: "LM",
            name: "Liam",
            onboardedAt: "2026-11-01T00:00:00Z",
            roleTitle: "Engineer"
        )
        XCTAssertFalse(LandingLogic.needsWizard(me: onboarded))
        XCTAssertEqual(
            LandingLogic.landingPath(me: onboarded, personas: [], defaultPersonaId: "p-default"),
            "/chat?new&persona=p-default"
        )

        let fresh = API.User(
            email: "me@localhost",
            harnessConnected: false,
            id: "u1",
            initials: "LU",
            name: "Local user",
            onboardedAt: nil,
            roleTitle: ""
        )
        XCTAssertTrue(LandingLogic.needsWizard(me: fresh))
        XCTAssertEqual(
            LandingLogic.landingPath(me: fresh, personas: [], defaultPersonaId: "p-default"),
            "/chat?new"
        )
    }
}
