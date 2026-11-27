import Foundation
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
}
