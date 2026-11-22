import XCTest
@testable import VesperCore

final class SettingsRouteResolverTests: XCTestCase {
    func testResolvesAllCanonicalAndLegacyWebRoutes() {
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings"), .pane(pane: .you))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings/"), .pane(pane: .you))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=appearance"), .pane(pane: .appearance))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=memory&id=mem-1"), .pane(pane: .memory, memoryFocusId: "mem-1"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=personas"), .pane(pane: .personas, personaFilter: .all))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=personas&filter=tickets"), .pane(pane: .personas, personaFilter: .tickets))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=personas&filter=chat"), .pane(pane: .personas, personaFilter: .chat))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=personas&persona=p1"), .pane(pane: .personas, personaId: "p1"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=persona&id=p2"), .pane(pane: .personas, personaId: "p2"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=persona"), .pane(pane: .personas, personaFilter: .all))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=secrets"), .pane(pane: .secrets, secretsTab: .provider))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=secrets&tab=api"), .pane(pane: .secrets, secretsTab: .api))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=secrets&secret=sec-1"), .pane(pane: .secrets, secretsTab: .api, secretId: "sec-1"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=secrets&tab=provider&secret=sec-1"), .pane(pane: .secrets, secretsTab: .provider, secretId: "sec-1"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=connectors"), .pane(pane: .connectors))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=repositories"), .pane(pane: .repositories))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=workspace#images"), .pane(pane: .workspace, anchor: "images"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=workspace#media"), .pane(pane: .workspace, anchor: "media"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=runners"), .pane(pane: .runners))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=dev-workspace"), .pane(pane: .devWorkspace))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=spaces&space=sp1#overrides"), .pane(pane: .spaces, spaceId: "sp1", anchor: "overrides"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=sign-in"), .pane(pane: .signIn))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=backup"), .pane(pane: .backups))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?section=backups"), .pane(pane: .backups))
    }

    func testResolvesImplicitParamsAndLegacyHashes() {
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?persona=p9"), .pane(pane: .personas, personaId: "p9"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?id=m7"), .pane(pane: .memory, memoryFocusId: "m7"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?space=sp2"), .pane(pane: .spaces, spaceId: "sp2"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings?secret=sec7"), .pane(pane: .secrets, secretsTab: .api, secretId: "sec7"))

        XCTAssertEqual(SettingsRouteResolver.resolve("/settings#secrets"), .pane(pane: .secrets, secretsTab: .provider))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings#images"), .pane(pane: .workspace, anchor: "images"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings#media"), .pane(pane: .workspace, anchor: "media"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings#overrides"), .pane(pane: .spaces, anchor: "overrides"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings#%61ppearance"), .pane(pane: .appearance))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings#backup"), .pane(pane: .backups))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings#general"), .pane(pane: .general))
    }

    func testResolvesRunnerProjectsCustomizationMemoryPersonasAndExactAgents() {
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings/runner"), .pane(pane: .runners, runnerRunId: nil))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings/runner?run_id=run-42"), .pane(pane: .runners, runnerRunId: "run-42"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings/projects?project=LAZY"), .spaceRedirect(projectKey: "LAZY"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/settings/projects"), .spaceRedirect(projectKey: nil))

        XCTAssertEqual(SettingsRouteResolver.resolve("/customization?who=person"), .pane(pane: .you))
        XCTAssertEqual(SettingsRouteResolver.resolve("/customization?who=personas"), .pane(pane: .personas, personaFilter: .all))
        XCTAssertEqual(SettingsRouteResolver.resolve("/customization?who=agents"), .pane(pane: .personas, personaFilter: .tickets))
        XCTAssertEqual(SettingsRouteResolver.resolve("/customization?who=connectors"), .pane(pane: .connectors))
        XCTAssertEqual(SettingsRouteResolver.resolve("/customization?who=secrets&secret=s1"), .pane(pane: .secrets, secretsTab: .api, secretId: "s1"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/customization?who=persona-42"), .pane(pane: .personas, personaId: "persona-42"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/customization?space=sp9#overrides"), .pane(pane: .spaces, spaceId: "sp9", anchor: "overrides"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/customization?id=m10"), .pane(pane: .memory, memoryFocusId: "m10"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/customization/anything"), .pane(pane: .memory))

        XCTAssertEqual(SettingsRouteResolver.resolve("/memory?id=m3"), .pane(pane: .memory, memoryFocusId: "m3"))
        XCTAssertEqual(SettingsRouteResolver.resolve("/personas"), .pane(pane: .personas, personaFilter: .all))
        XCTAssertEqual(SettingsRouteResolver.resolve("/agents"), .pane(pane: .personas, personaFilter: .tickets))

        // Individual agent pages and non-settings paths must not be intercepted.
        XCTAssertNil(SettingsRouteResolver.resolve("/agents/meow"))
        XCTAssertNil(SettingsRouteResolver.resolve("/inbox"))
        XCTAssertNil(SettingsRouteResolver.resolve("/tickets/PAY-1"))
    }

    func testMatchesFilterUsesAllWordsCaseInsensitively() {
        XCTAssertTrue(SettingsRouteResolver.matchesPane(.appearance, title: "Appearance", query: "  dark   harness "))
        XCTAssertTrue(SettingsRouteResolver.matchesPane(.secrets, title: "Credentials & API Secrets", query: "oauth github"))
        XCTAssertTrue(SettingsRouteResolver.matchesPane(.workspace, title: "Workspace", query: "omni video"))
        XCTAssertTrue(SettingsRouteResolver.matchesPane(.workspace, title: "Workspace", query: "tts voice"))
        XCTAssertTrue(SettingsRouteResolver.matchesPane(.workspace, title: "Workspace", query: "lyria music"))
        XCTAssertFalse(SettingsRouteResolver.matchesPane(.you, title: "You", query: "runner slots"))
    }
}
