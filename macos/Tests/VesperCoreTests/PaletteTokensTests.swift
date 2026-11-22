import XCTest
@testable import VesperCore

final class PaletteTokensTests: XCTestCase {
    func testAll18PresetsCoverCompleteColorContractAndContrast() {
        XCTAssertEqual(PaletteTokens.presets.count, 18)
        XCTAssertEqual(PaletteTokens.presets.first?.id, "neutral")
        XCTAssertEqual(Set(PaletteTokens.presets.map(\.id)).count, 18)

        let expectedKeys = PaletteTokens.presets[0].dark.keys.sorted()
        for preset in PaletteTokens.presets {
            for mode in [ColorMode.light, ColorMode.dark] {
                let resolved = PaletteTokens.resolvedRawTokens(
                    for: AppearancePreference(mode: mode == .dark ? .dark : .light, palette: preset.id),
                    mode: mode
                )
                XCTAssertEqual(resolved.keys.sorted(), expectedKeys, "\(preset.id) \(mode)")
                for key in PaletteTokens.colorKeys {
                    XCTAssertTrue(PaletteTokens.isHex(resolved[key] ?? ""), "\(preset.id) \(mode) \(key)")
                }
                let series = (1...8).compactMap { resolved["viz-\($0)"] }
                XCTAssertEqual(Set(series).count, 8, "\(preset.id) \(mode) unique chart colors")
                for color in series {
                    XCTAssertTrue(PaletteTokens.isOpaqueHex(color), "\(preset.id) \(mode) viz series opaque")
                }

                if preset.id != "dusk" {
                    for fg in ["text", "text-2", "text-secondary", "text-tertiary", "state-human", "state-blocked", "state-done"] {
                        for bg in ["bg", "surface", "surface-raised"] {
                            XCTAssertGreaterThanOrEqual(
                                PaletteTokens.contrast(resolved[fg]!, resolved[bg]!),
                                4.5,
                                "\(preset.id) \(mode) \(fg) on \(bg)"
                            )
                        }
                    }
                    XCTAssertGreaterThanOrEqual(PaletteTokens.contrast(resolved["text-on-accent"]!, resolved["accent"]!), 4.5)
                    XCTAssertGreaterThanOrEqual(PaletteTokens.contrast(resolved["approve-fg"]!, resolved["state-human"]!), 4.5)
                }
            }
        }
    }

    func testMacOSPresetAndSystemAccentDerivation() {
        let mac = PaletteTokens.palette(id: "macos")!
        XCTAssertEqual(mac.dark["bg"], "#1e1e1e")
        XCTAssertEqual(mac.light["bg"], "#ffffff")

        for mode in [ColorMode.dark, ColorMode.light] {
            let tokens = PaletteTokens.resolvedRawTokens(
                for: AppearancePreference(palette: "macos"),
                mode: mode,
                systemAccent: "#ff9500"
            )
            XCTAssertGreaterThanOrEqual(PaletteTokens.contrast(tokens["accent"]!, tokens["bg"]!), 3.0)
            XCTAssertEqual(tokens["accent-soft"], tokens["accent"]! + "26")
            XCTAssertEqual(tokens["segment-on"], tokens["selected"])
            XCTAssertGreaterThanOrEqual(PaletteTokens.contrast(tokens["text-on-accent"]!, tokens["accent"]!), 4.5)
            XCTAssertEqual(tokens["bg"], (mode == .dark ? mac.dark : mac.light)["bg"])
        }

        XCTAssertEqual(PaletteTokens.withSystemAccent(mac.dark, accent: "orange", mode: .dark), mac.dark)
    }

    func testCustomOverridesPreserveBaseAndRecomputeDependents() {
        let nord = PaletteTokens.palette(id: "nord")!
        XCTAssertEqual(
            PaletteTokens.resolvedRawTokens(
                for: AppearancePreference(palette: "custom", custom: CustomPaletteOverrides(base: "nord")),
                mode: .dark
            ),
            nord.dark
        )

        let custom = AppearancePreference(
            palette: "custom",
            custom: CustomPaletteOverrides(
                base: "nord",
                dark: ["surface": "#182128", "accent": "#aabbcc", "state-human": "#aabbcc", "viz-panel": "#123456"],
                light: ["bg": "#fff0ee"]
            )
        )
        let dark = PaletteTokens.resolvedRawTokens(for: custom, mode: .dark)
        let light = PaletteTokens.resolvedRawTokens(for: custom, mode: .light)

        XCTAssertEqual(dark["surface"], "#182128")
        XCTAssertEqual(dark["viz-surface"], dark["surface"])
        XCTAssertEqual(dark["viz-panel"], "#123456")
        XCTAssertEqual(dark["accent-soft"], "#aabbcc26")
        XCTAssertGreaterThanOrEqual(PaletteTokens.contrast(dark["text-on-accent"]!, dark["accent"]!), 4.5)
        XCTAssertNotEqual(dark["pill-human-bg"], nord.dark["pill-human-bg"])
        XCTAssertEqual(light["bg"], "#fff0ee")
        XCTAssertEqual(light["surface"], nord.light["surface"])
    }

    func testExportAndImportValidate40KBCapAndSanitizeHexValues() throws {
        let pref = AppearancePreference(
            mode: .light,
            palette: "custom",
            textSize: .large,
            showHarnessActivity: false,
            custom: CustomPaletteOverrides(base: "gruvbox", dark: ["accent": "#fabd2f"], light: [:])
        )
        let exported = try pref.exportPaletteJSON()
        let imported = try AppearancePreference.importPaletteJSON(
            exported,
            preserving: AppearancePreference(mode: .dark, palette: "neutral", textSize: .larger, showHarnessActivity: false)
        )
        XCTAssertEqual(imported.palette, "custom")
        XCTAssertEqual(imported.custom.base, "gruvbox")
        XCTAssertEqual(imported.custom.dark, ["accent": "#fabd2f"])
        XCTAssertEqual(imported.mode, .dark)
        XCTAssertEqual(imported.textSize, .larger)
        XCTAssertFalse(imported.showHarnessActivity)

        let tooBig = Data(repeating: UInt8(ascii: "a"), count: 40_001)
        XCTAssertThrowsError(try AppearancePreference.importPaletteJSON(tooBig, preserving: pref)) { err in
            XCTAssertEqual(err as? AppearancePreference.ImportError, .tooLarge)
        }

        let hostileJSON = Data(##"{"version":1,"palette":"custom","custom":{"base":"unknown","dark":{"bg":"red; evil()","text":"#ABCDEF","unknown-key":"#123456"}}}"##.utf8)
        let cleaned = try AppearancePreference.importPaletteJSON(hostileJSON, preserving: pref)
        XCTAssertEqual(cleaned.custom.base, "neutral")
        XCTAssertEqual(cleaned.custom.dark, ["text": "#abcdef"])
        XCTAssertEqual(cleaned.custom.light, [:])

        let wrongVersion = Data(#"{"version":2,"palette":"nord"}"#.utf8)
        XCTAssertThrowsError(try AppearancePreference.importPaletteJSON(wrongVersion, preserving: pref)) { err in
            XCTAssertEqual(err as? AppearancePreference.ImportError, .invalidFormat)
        }
    }

    func testContrastWarningsReportLowContrastPairs() {
        let low = AppearancePreference(
            palette: "custom",
            custom: CustomPaletteOverrides(base: "neutral", dark: ["bg": "#18181b", "text": "#202024"], light: [:])
        )
        let tokens = PaletteTokens.resolvedRawTokens(for: low, mode: .dark)
        let warnings = PaletteTokens.contrastWarnings(for: tokens)
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertTrue(warnings.contains(where: { $0.name.contains("Text on Background") }))
    }
}
