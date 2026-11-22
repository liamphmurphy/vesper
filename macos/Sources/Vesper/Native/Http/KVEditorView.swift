import SwiftUI
import VesperCore

// MARK: - Shared HTTP Styling & Components

enum HttpStyle {
    static func methodColor(_ method: String, theme: ThemeTokens) -> Color {
        let token = HttpClientLogic.methodColorToken(method)
        let fallback: Color = switch method.uppercased() {
        case "GET": .green
        case "POST": theme.palette.accent
        case "PUT", "PATCH": .orange
        case "DELETE": .red
        default: theme.palette.secondaryText
        }
        return theme.swiftUIColor(token, fallback: fallback)
    }

    static func envColor(_ color: HttpEnvColor, theme: ThemeTokens) -> Color {
        let fallback: Color = switch color {
        case .green: .green
        case .amber: .orange
        case .red: .red
        case .blue: .blue
        case .purple: .purple
        case .gray: .secondary
        }
        return theme.swiftUIColor(HttpClientLogic.envColorToken(color), fallback: fallback)
    }

    static func statusColors(statusCode: Int, error: String?, theme: ThemeTokens) -> (fg: Color, bg: Color) {
        let tone = HttpClientLogic.statusTone(statusCode: statusCode, error: error)
        let (fallbackFg, fallbackBg): (Color, Color) = switch tone {
        case "done": (.green, Color.green.opacity(0.14))
        case "human": (.orange, Color.orange.opacity(0.14))
        case "blocked": (.red, Color.red.opacity(0.14))
        default: (theme.palette.secondaryText, theme.palette.surface)
        }
        return (
            theme.swiftUIColor("pill-\(tone)-fg", fallback: fallbackFg),
            theme.swiftUIColor("pill-\(tone)-bg", fallback: fallbackBg)
        )
    }

    static func sidebarBackground(_ theme: ThemeTokens) -> Color {
        theme.swiftUIColor("sidebar", fallback: theme.palette.surface)
    }

    static func color(fromRGBAHex hex: String?) -> Color? {
        guard let hex, let rgba = RGBA(hex: hex) else { return nil }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

struct HttpInputBoxModifier: ViewModifier {
    let theme: ThemeTokens
    var mono: Bool = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? theme.font(.mono) : theme.font(.body))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
    }
}

extension View {
    func httpInputBox(_ theme: ThemeTokens, mono: Bool = false) -> some View {
        modifier(HttpInputBoxModifier(theme: theme, mono: mono))
    }
}

struct HttpCheckboxButton: View {
    @Environment(\.vesperTheme) private var theme
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? theme.palette.accent : theme.palette.tertiaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Enabled" : "Disabled")
    }
}

struct HttpMethodBadge: View {
    @Environment(\.vesperTheme) private var theme
    let method: String

    var body: some View {
        Text(HttpClientLogic.shortMethodLabel(method))
            .font(.system(size: theme.pointSize(.micro), weight: .bold, design: .monospaced))
            .foregroundStyle(HttpStyle.methodColor(method, theme: theme))
            .frame(minWidth: 34, alignment: .leading)
    }
}

struct HttpField<Content: View>: View {
    @Environment(\.vesperTheme) private var theme
    let label: String
    var hint: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: theme.pointSize(.small), weight: .medium))
                .foregroundStyle(theme.palette.secondaryText)
            content()
            if let hint, !hint.isEmpty {
                Text(hint)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.tertiaryText)
            }
        }
    }
}

struct HttpCard<Action: View, Content: View>: View {
    @Environment(\.vesperTheme) private var theme
    let title: String
    @ViewBuilder let action: () -> Action
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        @ViewBuilder action: @escaping () -> Action,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.action = action
        self.content = content
    }

    init(title: String, @ViewBuilder content: @escaping () -> Content) where Action == EmptyView {
        self.title = title
        self.action = { EmptyView() }
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .vesperText(.heading, theme)
                    .foregroundStyle(theme.palette.text)
                Spacer(minLength: 8)
                action()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(theme.palette.border)

            content()
                .padding(16)
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
    }
}

struct HttpEmptyState<Actions: View>: View {
    @Environment(\.vesperTheme) private var theme
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    init(
        icon: String = "powerplug",
        title: String,
        message: String,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions
    }

    init(icon: String = "powerplug", title: String, message: String) where Actions == EmptyView {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = { EmptyView() }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(theme.palette.tertiaryText)
            Text(title)
                .vesperText(.heading, theme)
                .foregroundStyle(theme.palette.text)
            Text(message)
                .vesperText(.body, theme)
                .foregroundStyle(theme.palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                actions()
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Key-Value Editor

struct KVEditorView: View {
    @Environment(\.vesperTheme) private var theme
    @Binding var items: [HttpKeyValue]
    var keyPlaceholder: String = "Key"
    var valuePlaceholder: String = "Value"
    var emptyLabel: String = "No entries yet."
    var addLabel: String = "Add row"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text(emptyLabel)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.tertiaryText)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 6) {
                            HttpCheckboxButton(
                                isOn: Binding(
                                    get: { index < items.count ? items[index].enabled : true },
                                    set: { newValue in
                                        if index < items.count { items[index].enabled = newValue }
                                    }
                                ),
                                label: "Enable \(row.key.isEmpty ? "row \(index + 1)" : row.key)"
                            )
                            TextField(
                                keyPlaceholder,
                                text: Binding(
                                    get: { index < items.count ? items[index].key : "" },
                                    set: { newValue in
                                        if index < items.count { items[index].key = newValue }
                                    }
                                )
                            )
                            .httpInputBox(theme, mono: true)
                            .frame(minWidth: 110, maxWidth: .infinity)

                            TextField(
                                valuePlaceholder,
                                text: Binding(
                                    get: { index < items.count ? items[index].value : "" },
                                    set: { newValue in
                                        if index < items.count { items[index].value = newValue }
                                    }
                                )
                            )
                            .httpInputBox(theme, mono: true)
                            .frame(minWidth: 140, maxWidth: .infinity)

                            Button {
                                if index < items.count { items.remove(at: index) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.palette.tertiaryText)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove row")
                        }
                    }
                }
            }

            Button {
                items.append(HttpKeyValue(key: "", value: "", enabled: true))
            } label: {
                Label(addLabel, systemImage: "plus")
            }
            .buttonStyle(.vesper())
        }
    }
}

// MARK: - Environment Variable & Secret Editor

struct EnvVarEditorView: View {
    @Environment(\.vesperTheme) private var theme
    @Binding var items: [HttpEnvVar]
    let secrets: [API.ApiSecret]
    var emptyLabel: String = "No variables in this environment yet."
    var addLabel: String = "Add variable"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text(emptyLabel)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.tertiaryText)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, row in
                        let usesSecret = !row.secretHandle.isEmpty
                        HStack(spacing: 6) {
                            HttpCheckboxButton(
                                isOn: Binding(
                                    get: { index < items.count ? items[index].enabled : true },
                                    set: { newValue in
                                        if index < items.count { items[index].enabled = newValue }
                                    }
                                ),
                                label: "Enable \(row.key.isEmpty ? "variable \(index + 1)" : row.key)"
                            )
                            TextField(
                                "variable_name",
                                text: Binding(
                                    get: { index < items.count ? items[index].key : "" },
                                    set: { newValue in
                                        if index < items.count { items[index].key = newValue }
                                    }
                                )
                            )
                            .httpInputBox(theme, mono: true)
                            .frame(minWidth: 110, maxWidth: .infinity)

                            if usesSecret {
                                if secrets.isEmpty {
                                    HStack(spacing: 4) {
                                        Text("secret:")
                                            .font(theme.font(.mono))
                                            .foregroundStyle(theme.palette.tertiaryText)
                                        TextField(
                                            "secret-handle",
                                            text: Binding(
                                                get: { index < items.count ? items[index].secretHandle : "" },
                                                set: { newValue in
                                                    if index < items.count { items[index].secretHandle = newValue }
                                                }
                                            )
                                        )
                                        .textFieldStyle(.plain)
                                        .font(theme.font(.mono))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                                    .frame(minWidth: 150, maxWidth: .infinity)
                                } else {
                                    Picker(
                                        "Vesper secret",
                                        selection: Binding(
                                            get: { index < items.count ? items[index].secretHandle : "" },
                                            set: { newValue in
                                                if index < items.count { items[index].secretHandle = newValue }
                                            }
                                        )
                                    ) {
                                        Text("Plain value\u{2026}").tag("")
                                        ForEach(secrets, id: \.id) { secret in
                                            Text("secret:\(secret.handle) (\(secret.name))")
                                                .tag(secret.handle)
                                        }
                                        if !row.secretHandle.isEmpty && !secrets.contains(where: { $0.handle == row.secretHandle }) {
                                            Text("secret:\(row.secretHandle)").tag(row.secretHandle)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                TextField(
                                    "https://api.nonprod.example.com",
                                    text: Binding(
                                        get: { index < items.count ? items[index].value : "" },
                                        set: { newValue in
                                            if index < items.count { items[index].value = newValue }
                                        }
                                    )
                                )
                                .httpInputBox(theme, mono: true)
                                .frame(minWidth: 150, maxWidth: .infinity)
                            }

                            Button {
                                guard index < items.count else { return }
                                if usesSecret {
                                    items[index].secretHandle = ""
                                } else {
                                    items[index].secretHandle = secrets.first?.handle ?? "api-token"
                                    items[index].value = ""
                                }
                            } label: {
                                Label(usesSecret ? "Secret" : "Plain", systemImage: usesSecret ? "lock" : "key")
                                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                            }
                            .buttonStyle(.vesper())
                            .help(usesSecret ? "Switch to plain value" : "Use a Vesper secret")

                            Button {
                                if index < items.count { items.remove(at: index) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.palette.tertiaryText)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove variable")
                        }
                    }
                }
            }

            Button {
                items.append(HttpEnvVar(key: "", value: "", secretHandle: "", enabled: true))
            } label: {
                Label(addLabel, systemImage: "plus")
            }
            .buttonStyle(.vesper())
        }
    }
}
