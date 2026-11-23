import XCTest
@testable import VesperCore

final class SubagentTierRulesTests: XCTestCase {
    private func makeModel(_ id: String, _ label: String = "") -> API.ChatModel {
        API.ChatModel(default: false, defaultEffort: nil, efforts: [], id: id, label: label)
    }

    func testSelectableModelsFiltersOrchestrators() {
        let models = [
            makeModel("gemini-4-carbon", "Gemini 4 Carbon"),
            makeModel("gemini-pro-orchestrator", "Orchestrator (Carbon)"),
            makeModel("gemini-4-neon", "Gemini 4 Neon"),
            makeModel("gemini-pro-orchestrator-neon", "Orchestrator (Neon)"),
            makeModel("gemini-4-hydrogen", "Gemini 4 Hydrogen"),
        ]
        XCTAssertEqual(
            SubagentTierRulesLogic.selectableModels(models).map(\.id),
            ["gemini-4-carbon", "gemini-4-neon", "gemini-4-hydrogen"]
        )
        XCTAssertEqual(SubagentTierRulesLogic.selectableModels(nil), [])
    }

    func testIsStaleModelFlagsRetiredOnlyWithLoadedCatalog() {
        let live = [
            makeModel("gemini-4-carbon"),
            makeModel("gemini-4-neon"),
            makeModel("gemini-4-hydrogen"),
        ]
        XCTAssertFalse(SubagentTierRulesLogic.isStaleModel("gemini-4-neon", catalog: live))
        XCTAssertFalse(SubagentTierRulesLogic.isStaleModel("GEMINI-4-NEON", catalog: live))
        XCTAssertTrue(SubagentTierRulesLogic.isStaleModel("gemini-3.8-flash", catalog: live))
        XCTAssertFalse(SubagentTierRulesLogic.isStaleModel("", catalog: live))
        XCTAssertFalse(SubagentTierRulesLogic.isStaleModel(nil, catalog: live))
        XCTAssertFalse(SubagentTierRulesLogic.isStaleModel("gemini-3.8-flash", catalog: []))
        XCTAssertFalse(SubagentTierRulesLogic.isStaleModel("gemini-3.8-flash", catalog: nil))
    }

    func testSettingAndClearingRulesMaintainsCleanMap() {
        var rules = SubagentTierRulesLogic.settingModel(in: [:], harness: "antigravity", tier: .deep, modelId: " gemini-4-carbon ")
        rules = SubagentTierRulesLogic.settingModel(in: rules, harness: "antigravity", tier: .standard, modelId: "gemini-4-neon")
        rules = SubagentTierRulesLogic.settingModel(in: rules, harness: "antigravity", tier: .fast, modelId: "gemini-4-hydrogen")
        XCTAssertEqual(rules["antigravity"], API.SubagentTierModels(deep: "gemini-4-carbon", fast: "gemini-4-hydrogen", standard: "gemini-4-neon"))

        rules = SubagentTierRulesLogic.settingModel(in: rules, harness: "claude-code", tier: .fast, modelId: "haiku")
        rules = SubagentTierRulesLogic.settingModel(in: rules, harness: "claude-code", tier: .fast, modelId: "")
        XCTAssertNil(rules["claude-code"])
        XCTAssertEqual(rules["antigravity"]?.deep, "gemini-4-carbon")

        let cleared = SubagentTierRulesLogic.clearingHarness(in: rules, harness: "antigravity")
        XCTAssertTrue(cleared.isEmpty)
    }
}
