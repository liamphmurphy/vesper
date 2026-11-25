import SwiftUI
import VesperCore

/// Renders a custom 64x64 animated SVG persona character natively (`PersonaCharacterRig`):
/// - `active == true` and animation allowed (`AnimationPolicy`): the state's motions at the
///   display's refresh rate, restarting from their first frame whenever what's shown changes, as
///   the web view's CSS animations restarted with each page load.
/// - otherwise (inactive, Reduce Motion, hidden window, Low Power Mode for idle): the still
///   `static` frame with no timeline at all, as the web snapshots showed.
struct PersonaCharacterView: View {
    let svg: String
    let color: String
    var state: CharacterState = .staticState
    var size: CGFloat = 24
    var active: Bool = false
    var framed: Bool = false
    /// Clips the character to a circle. Drawing never spills past the view's square, so this only
    /// adds the circular mask `framed` already applies.
    var clipped: Bool = false

    @Environment(\.vesperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vesperWindowVisible) private var windowVisible

    var body: some View {
        let pad = framed ? max(1, (size * 0.06).rounded()) : 0
        let tintAlpha = theme.mode == .dark ? 0.15 : 0.20
        let accentColor = Color(cssHex: PersonaCharacterSanitizer.safeHexColor(color)) ?? .gray
        let isActiveState = state != .idle && state != .staticState
        let liveAllowed = active && AnimationPolicy.shouldAnimate(
            working: isActiveState,
            context: AppPowerState.shared.animationContext(
                reduceMotion: reduceMotion,
                windowVisible: windowVisible
            )
        )
        let rig = PersonaCharacterRigCache.rig(svg: svg, color: color)
        let shownState: CharacterState = liveAllowed ? state : .staticState
        let animates = rig?.animates(in: shownState) ?? false

        Group {
            if let rig {
                if animates {
                    // A new identity per run gives the canvas a fresh clock.
                    AnimatedCharacterCanvas(rig: rig, state: shownState)
                        .id(AnimationRun(svg: svg, color: color, state: shownState))
                } else {
                    CharacterCanvas(rig: rig, state: shownState, time: 0)
                }
            }
        }
        .padding(pad)
        .frame(width: size, height: size)
        .background {
            if framed {
                Circle()
                    .fill(theme.palette.background)
                    .overlay(Circle().fill(accentColor.opacity(tintAlpha)))
            }
        }
        .modifier(CircleClipModifier(enabled: framed || clipped))
        .accessibilityHidden(true)
    }

    /// What a run of the animations shows; a change starts them over.
    private struct AnimationRun: Hashable {
        var svg: String
        var color: String
        var state: CharacterState
    }
}

/// The state's motions at the display's refresh rate, timed from when this view appeared.
private struct AnimatedCharacterCanvas: View {
    let rig: PersonaCharacterRig
    let state: CharacterState

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            CharacterCanvas(rig: rig, state: state, time: timeline.date.timeIntervalSince(start))
        }
    }
}

private struct CharacterCanvas: View {
    let rig: PersonaCharacterRig
    let state: CharacterState
    let time: TimeInterval

    var body: some View {
        Canvas { ctx, canvasSize in
            ctx.withCGContext { cg in
                rig.draw(state: state, at: time, in: cg, rect: CGRect(origin: .zero, size: canvasSize))
            }
        }
    }
}

/// Compiled characters by SVG and colour, so every row showing a persona shares one parse.
@MainActor
enum PersonaCharacterRigCache {
    private struct Key: Hashable {
        var svg: String
        var color: String
    }

    /// Distinct personas and colours on screen stay far below this; it only bounds a long session.
    private static let limit = 128
    private static var rigs: [Key: PersonaCharacterRig?] = [:]

    static func rig(svg: String, color: String) -> PersonaCharacterRig? {
        let key = Key(svg: svg, color: PersonaCharacterSanitizer.safeHexColor(color).lowercased())
        if let hit = rigs[key] { return hit }
        if rigs.count >= limit { rigs.removeAll(keepingCapacity: true) }
        let rig = PersonaCharacterRig(svg: svg, color: key.color)
        rigs[key] = rig
        return rig
    }
}

private struct CircleClipModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.clipShape(Circle()) } else { content }
    }
}
