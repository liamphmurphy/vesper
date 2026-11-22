import AppKit
import SwiftUI
import VesperCore

/// A ticket or run agent drawn as the person's matching persona (web WorkPersonaAvatar): its
/// photo when it has one, else its cached custom animated character snapshot (`characterSvg`,
/// `active: false`), else a circle with its initial in the persona's colour (or the agent's
/// identity hue).
struct WorkPersonaAvatarView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let id: String?
    let handle: String?
    let name: String
    var colorIndex: Int = 0
    var size: CGFloat = 24
    var state: CharacterState = .staticState
    var active: Bool = false

    @State private var picture: NSImage?

    private static let personas = API.listPersonas()

    var body: some View {
        let persona = WorkPersona.match(context.store.entry(Self.personas).data?.personas ?? [], id: id, handle: handle, name: name)
        let hue = WorkPersona.hue(colorIndex)
        let fill = Color(cssHex: persona?.color) ?? theme.swiftUIColor("agent-\(hue)", fallback: .gray)
        let fallbackHex = theme.colors["agent-\(hue)"] ?? "#64748b"
        let characterColor = persona.flatMap { $0.color.isEmpty ? nil : $0.color } ?? fallbackHex
        let hasPhoto = !(persona?.avatarUrl ?? "").isEmpty
        let characterSvg = hasPhoto ? nil : persona?.characterSvg.flatMap { $0.isEmpty ? nil : $0 }

        ZStack {
            if let picture {
                Image(nsImage: picture).resizable().scaledToFill()
            } else if let characterSvg {
                PersonaCharacterView(
                    svg: characterSvg,
                    color: characterColor,
                    state: state,
                    size: size,
                    active: active,
                    framed: true
                )
            } else {
                Circle().fill(fill)
                Text(String((persona?.name ?? name).prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("\(persona?.name ?? name) (agent)")
        .task { context.store.load(Self.personas) }
        .task(id: persona?.avatarUrl) {
            picture = nil
            if let url = persona?.avatarUrl, !url.isEmpty { picture = await AvatarImages.shared.image(for: url) }
        }
    }
}

extension WorkPersonaAvatarView {
    init(agent: API.AgentRef, size: CGFloat = 24, state: CharacterState = .staticState, active: Bool = false) {
        self.init(id: agent.id, handle: agent.handle, name: agent.name, colorIndex: agent.colorIndex, size: size, state: state, active: active)
    }
}

/// The web's status pills (`bg-pill-<tone>-bg text-pill-<tone>-fg`).
struct TonePill: View {
    @Environment(\.vesperTheme) private var theme
    let label: String
    /// "human", "blocked", "review", "done" or "neutral".
    let tone: String

    var body: some View {
        Text(label)
            .font(.system(size: theme.pointSize(.small), weight: .medium))
            .foregroundStyle(theme.swiftUIColor("pill-\(tone)-fg", fallback: .primary))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(theme.swiftUIColor("pill-\(tone)-bg", fallback: Color.secondary.opacity(0.15)), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A key cap (the web's <Kbd>).
struct KeyCap: View {
    @Environment(\.vesperTheme) private var theme
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: theme.pointSize(.micro) + 1, weight: .medium, design: .monospaced))
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.swiftUIColor("kbd-border", fallback: Color.secondary.opacity(0.4))))
    }
}

/// A loading placeholder bar (the web's <Skeleton>).
struct SkeletonBar: View {
    @Environment(\.vesperTheme) private var theme
    var height: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(theme.swiftUIColor("track", fallback: Color.secondary.opacity(0.12)))
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}

/// The web's button variants.
struct VesperButtonStyle: ButtonStyle {
    enum Variant { case primary, outline, approve, approveOutline, danger }
    @Environment(\.vesperTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var variant: Variant = .outline

    func makeBody(configuration: Configuration) -> some View {
        let p = theme.palette
        let (fg, bg, border): (Color, Color, Color) = switch variant {
        case .primary: (theme.swiftUIColor("text-on-accent", fallback: .white), p.accent, .clear)
        case .outline: (p.text, theme.swiftUIColor("btn-outline-bg", fallback: p.surface), theme.swiftUIColor("btn-secondary-border", fallback: p.border))
        case .approve: (theme.swiftUIColor("approve-fg", fallback: .white), theme.swiftUIColor("state-human", fallback: .orange), .clear)
        case .approveOutline: (theme.swiftUIColor("state-human", fallback: .orange), p.surface, theme.swiftUIColor("state-human", fallback: .orange))
        case .danger: (theme.swiftUIColor("pill-blocked-fg", fallback: .red), p.surface, p.border)
        }
        return configuration.label
            .font(.system(size: theme.pointSize(.body), weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(bg.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(border))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == VesperButtonStyle {
    static func vesper(_ variant: VesperButtonStyle.Variant = .outline) -> VesperButtonStyle { VesperButtonStyle(variant: variant) }
}

/// A full-height error line with Retry, as the web screens show when a query fails.
struct QueryErrorView: View {
    @Environment(\.vesperTheme) private var theme
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            Button("Retry", action: retry).buttonStyle(.vesper())
        }
        .vesperText(.body, theme)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Loads an image from a Vesper API path (via `LibraryImages` + `APIClient` with the session cookie)
/// or an external http(s) URL, avoiding unauthenticated `AsyncImage` 401 failures on protected routes.
struct AuthenticatedImageView<Content: View, Placeholder: View, Failure: View>: View {
    @Environment(NativeScreenContext.self) private var context

    let source: String
    var maxPixel: CGFloat? = 920
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure

    @State private var image: NSImage?
    @State private var failed = false

    private var apiPath: String? {
        if source.hasPrefix("/api/v1/") { return source }
        guard let url = URL(string: source),
              let base = context.baseURL(),
              BridgeOrigin.matches(url: url, base: base),
              url.path.hasPrefix("/api/v1/") else { return nil }
        return url.query.map { "\(url.path)?\($0)" } ?? url.path
    }

    var body: some View {
        Group {
            if let image {
                content(Image(nsImage: image))
            } else if failed {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: "\(source)|\(context.store.client != nil)") {
            image = nil
            failed = false
            if let path = apiPath {
                guard let client = context.store.client else { return }
                image = await LibraryImages.shared.image(path: path, maxPixel: maxPixel, client: client)
                failed = (image == nil)
                return
            }
            guard let url = context.resolvedURL(source),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                failed = true
                return
            }
            if let (data, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let decoded = NSImage(data: data) {
                image = decoded
            } else {
                failed = true
            }
        }
    }
}
