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

    func testAppsHomeNavModelAndCommands() {
        let app = API.CustomAppSummary(
            capabilities: [:],
            createdAt: "2026-11-20T00:00:00Z",
            currentSeq: 1,
            dbSizeBytes: 4096,
            description: "Track expenses",
            hasMcpServer: false,
            icon: "dollar",
            id: "a1",
            manifest: API.CustomAppManifest(entry: "index.tsx", toolScope: .appOnly),
            mcpTools: nil,
            mounts: nil,
            name: "Budget",
            slug: "budget",
            spaceId: nil,
            updatedAt: "2026-11-20T00:00:00Z"
        )
        let nav = AppsHomeLogic.navModel(apps: [app], devWorkspaceEnabled: true)
        XCTAssertEqual(nav.id, AppsHomeLogic.navId)
        XCTAssertEqual(nav.sections.map(\.id), ["your-apps", "tools", "starters"])
        XCTAssertEqual(nav.sections[0].items.map(\.id), ["app:budget"])
        XCTAssertEqual(nav.sections[1].items.last?.href, "/dev")

        let filtered = AppsHomeLogic.navModel(apps: [app], search: "http", devWorkspaceEnabled: false)
        XCTAssertEqual(filtered.sections.first(where: { $0.id == "tools" })?.items.map(\.href), ["/http"])

        XCTAssertEqual(
            AppsHomeLogic.navAction(for: .navAction(navigatorId: AppsHomeLogic.navId, actionId: AppsHomeLogic.newAppAction)),
            .newApp(.blank)
        )
        XCTAssertEqual(
            AppsHomeLogic.navAction(for: .navActivate(navigatorId: AppsHomeLogic.navId, itemId: "app:budget", newTab: true)),
            .openPath("/apps/budget", newTab: true)
        )
        XCTAssertEqual(
            AppsHomeLogic.navAction(for: .navActivate(navigatorId: AppsHomeLogic.navId, itemId: "tool:/http", newTab: false)),
            .openPath("/http", newTab: false)
        )
        XCTAssertEqual(
            AppsHomeLogic.navAction(for: .navActivate(navigatorId: AppsHomeLogic.navId, itemId: "starter:ledger")),
            .newApp(.ledger)
        )
        XCTAssertEqual(
            AppsHomeLogic.navAction(for: .navAction(navigatorId: AppsHomeLogic.navId, actionId: AppsHomeLogic.deleteAppMenu, itemId: "app:budget")),
            .deleteApp(slug: "budget")
        )
        XCTAssertEqual(
            AppsHomeLogic.navAction(for: .navSearch(navigatorId: AppsHomeLogic.navId, searchId: AppsHomeLogic.searchId, value: "bud")),
            .search("bud")
        )
    }
}
