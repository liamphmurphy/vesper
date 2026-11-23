import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

// MARK: - Appearance & Color helpers

func hexString(from color: Color) -> String? {
    guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    let r = max(0, min(255, Int((srgb.redComponent * 255).rounded())))
    let g = max(0, min(255, Int((srgb.greenComponent * 255).rounded())))
    let b = max(0, min(255, Int((srgb.blueComponent * 255).rounded())))
    return String(format: "#%02x%02x%02x", r, g, b)
}

// MARK: - Formatting helpers

enum SettingsDateFormatter {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw)
    }

    static func absolute(_ raw: String?) -> String {
        guard let d = parse(raw) else { return raw ?? "Never" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ raw: String?) -> String {
        guard let d = parse(raw) else { return raw ?? "Never" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Shared UI chrome for Settings panes

struct SettingsScrollContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct SettingsPaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

struct SettingsCard<Trailing: View, Content: View>: View {
    let title: String?
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(
        _ title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title).font(.headline)
                        }
                        if let subtitle {
                            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    trailing()
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct SettingsBadge: View {
    let label: String
    let tone: SettingsBadgeTone

    private var tint: Color {
        switch tone {
        case .done: return .green
        case .human: return .orange
        case .blocked: return .red
        case .neutral: return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct SettingsBanner<Actions: View>: View {
    let tone: SettingsBadgeTone
    let title: String
    let message: String?
    @ViewBuilder var actions: () -> Actions

    init(
        tone: SettingsBadgeTone = .neutral,
        title: String,
        message: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.actions = actions
    }

    private var tint: Color {
        switch tone {
        case .done: return .green
        case .human: return .orange
        case .blocked: return .red
        case .neutral: return .accentColor
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                if let message, !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 0.75))
    }
}

struct SettingsAvatarView: View {
    let avatarURL: String?
    let initials: String
    let colorHex: String?
    var size: CGFloat = 44

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(Color(cssHex: colorHex) ?? Color.accentColor)
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: avatarURL) {
            image = nil
            if let avatarURL, !avatarURL.isEmpty {
                image = await AvatarImages.shared.image(for: avatarURL)
            }
        }
    }
}

struct SettingsUnavailableCard: View {
    let title: String
    let error: APIError?
    let retry: () -> Void

    var body: some View {
        SettingsBanner(
            tone: .blocked,
            title: title,
            message: error?.userMessage ?? "Start the Vesper server to configure this."
        ) {
            Button("Retry", action: retry)
        }
    }
}

// MARK: - File panel & query helpers

@MainActor
enum SettingsFilePanels {
    static func pickSaveURL(defaultName: String, contentTypes: [UTType], title: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = contentTypes
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func pickOpenURL(contentTypes: [UTType], title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveText(_ text: String, defaultName: String, contentType: UTType, title: String) throws -> URL? {
        guard let url = pickSaveURL(defaultName: defaultName, contentTypes: [contentType], title: title) else { return nil }
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    static func saveData(_ data: Data, defaultName: String, contentType: UTType, title: String) throws -> URL? {
        guard let url = pickSaveURL(defaultName: defaultName, contentTypes: [contentType], title: title) else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }

    static func openImageForAvatar() -> (url: URL, data: Data, fileName: String, mimeType: String)? {
        guard let url = pickOpenURL(contentTypes: [.png, .jpeg, .webP], title: "Choose an Avatar Image") else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "webp": mime = "image/webp"
        default: mime = ""
        }
        return (url, data, url.lastPathComponent, mime)
    }

    /// A video the person picked for a state loop, or why it can't be used. The size is checked
    /// before reading, so a huge file is never loaded only for the server to refuse it.
    static func openStateClip(maxBytes: Int) -> Result<(data: Data, fileName: String, mimeType: String), StateClipPickError>? {
        guard let url = pickOpenURL(contentTypes: [.mpeg4Movie, .quickTimeMovie], title: "Choose a Clip") else { return nil }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
            return .failure(.tooLarge)
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        let mime = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        return .success((data, url.lastPathComponent, mime))
    }

    enum StateClipPickError: Error {
        case tooLarge, unreadable
    }

    static func confirm(title: String, message: String, confirmLabel: String, destructive: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .critical : .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmLabel)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

func settingsErrorText(_ error: Error) -> String {
    if let api = error as? APIError { return api.userMessage }
    return error.localizedDescription
}
