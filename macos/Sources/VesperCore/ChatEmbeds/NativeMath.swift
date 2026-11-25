import CoreGraphics
import Foundation
import SwiftMath

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Lays TeX out with SwiftMath (Latin Modern Math) and draws it into a one-page vector PDF, the shape
/// every other rendered embed has. No web view: this is what chat math, inline `$$` in markdown and
/// the iOS companion all draw with.
///
/// Must run on the main actor: SwiftMath's font manager and typesetter share state without locks.
@MainActor
public enum NativeMath {
    /// KaTeX sets math at 1.21 times the surrounding text; keeping that keeps the chat's proportions.
    public static let fontScale = 1.21
    /// Room around the glyphs so accents and descenders aren't clipped at the image's edge.
    static let padding = 1.0

    /// The drawn math, or nil when the TeX doesn't parse (an unknown command, unbalanced braces).
    /// The caller keeps showing the source then, as it does for any embed that can't be drawn.
    public static func render(_ request: MathRenderRequest) -> RenderedEmbed? {
        guard !request.tex.isEmpty,
              let font = VesperMathTypesetter.latinModern(size: request.fontSize * fontScale),
              let rgba = RGBA(hex: request.color) else { return nil }
        let color = MTColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        // Typeset once to measure, then place the baseline `descent` above the bottom (PDF space is
        // y-up, as SwiftMath draws).
        guard let measured = VesperMathTypesetter.line(latex: request.tex, font: font, display: request.display, color: color) else { return nil }
        let width = measured.width + 2 * padding
        let ascent = measured.ascent + padding
        let height = ascent + measured.descent + padding
        guard width >= 1, height >= 1,
              let line = VesperMathTypesetter.line(latex: request.tex, font: font, display: request.display, color: color,
                                                   origin: CGPoint(x: padding, y: measured.descent + padding))
        else { return nil }

        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        line.draw(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return RenderedEmbed(pdf: data as Data, width: width, height: height, ascent: ascent)
    }
}
