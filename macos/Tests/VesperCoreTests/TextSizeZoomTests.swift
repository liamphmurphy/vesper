import Foundation
#if os(macOS)
import AppKit
#endif
import Testing
@testable import VesperCore

struct TextSizeZoomTests {
    @Test func allCasesAreStrictlyIncreasing() {
        let scales = AppearanceTextSize.allCases.map(\.scale)
        #expect(scales.first == 0.80)
        #expect(scales.last == 1.75)
        for i in 1..<scales.count {
            #expect(scales[i] > scales[i - 1])
        }
    }

    @Test func legacyPresetsKeepExactScales() {
        #expect(AppearanceTextSize.small.scale == 0.92)
        #expect(AppearanceTextSize.default.scale == 1.0)
        #expect(AppearanceTextSize.large.scale == 1.12)
        #expect(AppearanceTextSize.larger.scale == 1.25)
    }

    @Test func steppingClampsAtBounds() {
        var current = AppearanceTextSize.default
        for _ in 0..<20 {
            current = current.steppedIn()
        }
        #expect(current == .xxxlarge)
        #expect(!current.canStepIn)
        #expect(current.canStepOut)

        for _ in 0..<20 {
            current = current.steppedOut()
        }
        #expect(current == .xsmall)
        #expect(!current.canStepOut)
        #expect(current.canStepIn)
    }

    @Test func themeTokensUsesAppearanceTextSizeScale() {
        for size in AppearanceTextSize.allCases {
            let tokens = ThemeTokens(mode: .dark, textSize: size.rawValue)
            #expect(tokens.typeScale == size.scale)
            #expect(tokens.pointSize(.body) == ThemeTokens.TextStyle.body.metrics.size * size.scale)
        }
        #expect(ThemeTokens(mode: .dark, textSize: nil).typeScale == 1.0)
        #expect(ThemeTokens(mode: .dark, textSize: "unknown").typeScale == 1.0)
    }

    @Test func percentLabelFormatting() {
        #expect(AppearanceTextSize.xsmall.percentLabel == "80%")
        #expect(AppearanceTextSize.default.percentLabel == "100%")
        #expect(AppearanceTextSize.xxxlarge.percentLabel == "175%")
    }

    @Test func contentTextScaleClampsAndFormats() {
        #expect(AppearancePreference.clampContentTextScale(0.1) == 0.80)
        #expect(AppearancePreference.clampContentTextScale(3.0) == 1.75)
        #expect(AppearancePreference.clampContentTextScale(.nan) == 1.0)
        #expect(AppearancePreference.clampContentTextScale(.infinity) == 1.0)
        #expect(AppearancePreference.clampContentTextScale(1.254) == 1.25)

        let pref = AppearancePreference(contentTextScale: 1.35)
        #expect(pref.contentTextScale == 1.35)
        #expect(pref.contentTextPercentLabel == "135%")
    }

    @Test func appearancePreferenceDecodesLegacyJSONWithoutContentTextScale() throws {
        let legacyJSON = #"{"mode":"dark","palette":"dusk","textSize":"large","custom":{"base":"neutral","dark":{},"light":{}}}"#
        let decoded = try JSONDecoder().decode(AppearancePreference.self, from: Data(legacyJSON.utf8))
        #expect(decoded.mode == .dark)
        #expect(decoded.palette == "dusk")
        #expect(decoded.textSize == .large)
        #expect(decoded.contentTextScale == 1.0)
    }

    @Test func normalizeAndImportPreserveContentTextScale() throws {
        let normalized = AppearancePreference.normalize(["textSize": "small", "contentTextScale": 1.45])
        #expect(normalized.textSize == .small)
        #expect(normalized.contentTextScale == 1.45)

        let clamped = AppearancePreference.normalize(["contentTextScale": 9.9])
        #expect(clamped.contentTextScale == 1.75)

        let exported = try AppearancePreference(palette: "nord").exportPaletteJSON()
        let imported = try AppearancePreference.importPaletteJSON(exported, preserving: normalized)
        #expect(imported.palette == "nord")
        #expect(imported.textSize == .small)
        #expect(imported.contentTextScale == 1.45)
    }

    @Test func contentScaleIsIndependentOfInterfaceTypeScale() {
        let tokens = ThemeTokens(mode: .dark, textSize: AppearanceTextSize.xxxlarge.rawValue, contentTextScale: 1.25)
        #expect(tokens.typeScale == 1.75)
        #expect(tokens.contentScale == 1.25)
        #expect(tokens.pointSize(.body) == ThemeTokens.TextStyle.body.metrics.size * 1.75)
        #expect(tokens.contentPointSize(.body) == ThemeTokens.TextStyle.body.metrics.size * 1.25)
    }

    #if os(macOS)
    @MainActor
    @Test func markdownRendererUsesContentScaleNotInterfaceTypeScale() {
        let doc = MarkdownParser.parse("Hello world")
        let uiZoomedOnly = ThemeTokens(mode: .dark, textSize: AppearanceTextSize.xxxlarge.rawValue, contentTextScale: 1.0)
        let contentScaledOnly = ThemeTokens(mode: .dark, textSize: AppearanceTextSize.xsmall.rawValue, contentTextScale: 1.5)

        let renderedUIZoom = MarkdownRenderer.render(doc, theme: uiZoomedOnly, options: MarkdownRenderOptions(textStyle: .reading))
        let renderedContentScale = MarkdownRenderer.render(doc, theme: contentScaledOnly, options: MarkdownRenderOptions(textStyle: .reading))

        let uiFont = renderedUIZoom.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let contentFont = renderedContentScale.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont

        #expect(uiFont.map { Double($0.pointSize) } == ThemeTokens.TextStyle.reading.metrics.size * 1.0)
        #expect(contentFont.map { Double($0.pointSize) } == ThemeTokens.TextStyle.reading.metrics.size * 1.5)
    }
    #endif
}
