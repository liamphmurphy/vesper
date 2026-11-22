import SwiftUI
import VesperCore

/// Renders a custom 64x64 animated SVG persona character:
/// - `active == true`: uses the single pooled live `WKWebView` with CSS animations (frozen when Reduce Motion is enabled).
/// - `active == false`: uses a cached offscreen snapshot with zero live web views.
struct PersonaCharacterView: View {
    let svg: String
    let color: String
    var state: CharacterState = .staticState
    var size: CGFloat = 24
    var active: Bool = false
    var framed: Bool = false
    var clipped: Bool = false

    @Environment(\.vesperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var ownerID = UUID()
    @State private var snapshotImage: Image?

    private var snapshotState: CharacterState {
        active ? .staticState : state
    }

    private var pixelSize: Int {
        max(32, Int((size * max(1, displayScale)).rounded()))
    }

    private var snapshotKey: String {
        PersonaCharacterSanitizer.cacheKey(
            svg: svg,
            color: color,
            state: snapshotState,
            pixelSize: pixelSize,
            clipped: clipped
        )
    }

    var body: some View {
        let pad = framed ? max(1, (size * 0.06).rounded()) : 0
        let tintAlpha = theme.mode == .dark ? 0.15 : 0.20
        let accentColor = Color(cssHex: PersonaCharacterSanitizer.safeHexColor(color)) ?? .gray
        let showsLive = active && PersonaCharacterPool.shared.displayedLiveOwnerID == ownerID
        let cached = snapshotImage ?? PersonaCharacterPool.shared.cachedSnapshot(
            svg: svg,
            color: color,
            state: snapshotState,
            pixelSize: pixelSize,
            clipped: clipped
        )

        ZStack {
            if !showsLive, let cached {
                cached
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
            if active {
                PersonaCharacterPlatformHost(
                    ownerID: ownerID,
                    svg: svg,
                    color: color,
                    state: state,
                    clipped: clipped,
                    reduceMotion: reduceMotion
                )
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
        .task(id: snapshotKey) {
            if let hit = PersonaCharacterPool.shared.cachedSnapshot(
                svg: svg,
                color: color,
                state: snapshotState,
                pixelSize: pixelSize,
                clipped: clipped
            ) {
                snapshotImage = hit
                return
            }
            snapshotImage = nil
            snapshotImage = await PersonaCharacterPool.shared.snapshot(
                svg: svg,
                color: color,
                state: snapshotState,
                pixelSize: pixelSize,
                clipped: clipped
            )
        }
    }
}

private struct CircleClipModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.clipShape(Circle()) } else { content }
    }
}
