// Vesper addition, not upstream: the one public entry point Vesper needs. Upstream keeps the
// typesetter, a display's position and its colour internal (they're reached through MTMathUILabel,
// an NSView/UIView); Vesper lays math out off-screen into PDFs, with no view.
import CoreGraphics
import Foundation

public enum VesperMathTypesetter {
    /// Latin Modern Math at `size` (upstream's default font), loaded from the font bundle on first use.
    public static func latinModern(size: CGFloat) -> MTFont? {
        MTFontManager.fontManager.latinModernFont(withSize: size)
    }

    /// The typeset line for `latex` in `font`, coloured `color`, with its baseline at `origin`; nil
    /// when the TeX doesn't parse.
    public static func line(latex: String, font: MTFont, display: Bool, color: MTColor, origin: CGPoint = .zero) -> MTMathListDisplay? {
        var error: NSError?
        guard let list = MTMathListBuilder.build(fromString: latex, error: &error), error == nil,
              let line = MTTypesetter.createLineForMathList(list, font: font, style: display ? .display : .text)
        else { return nil }
        line.textColor = color
        line.position = origin
        return line
    }
}
