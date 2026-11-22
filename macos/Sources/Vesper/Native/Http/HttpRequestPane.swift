import SwiftUI
import VesperCore

enum HttpRequestTab: String, CaseIterable, Identifiable {
    case params
    case headers
    case auth
    case body
    case settings

    var id: String { rawValue }
}

struct HttpRequestPane: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @Binding var draft: HttpRequestDraft
    @Binding var selectedTab: HttpRequestTab
    let bundle: HttpWorkspaceBundle
    let secrets: [API.ApiSecret]

    @State private var timeoutText = ""

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(theme.palette.border)
            ScrollView {
                tabContent
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: draft.timeoutMs, initial: true) { _, next in
            let asString = String(next)
            if timeoutText != asString {
                timeoutText = asString
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(HttpRequestTab.allCases) { tab in
                    let active = selectedTab == tab
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tabTitle(for: tab))
                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                            .foregroundStyle(active ? theme.palette.text : theme.palette.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(active ? theme.palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func tabTitle(for tab: HttpRequestTab) -> String {
        switch tab {
        case .params:
            return draft.params.isEmpty ? "Params" : "Params (\(draft.params.count))"
        case .headers:
            return draft.headers.isEmpty ? "Headers" : "Headers (\(draft.headers.count))"
        case .auth:
            let suffix = draft.auth.type == .inherit ? "Inherited" : draft.auth.type.rawValue
            return "Auth (\(suffix))"
        case .body:
            return draft.bodyMode == .none ? "Body" : "Body (\(draft.bodyMode.label))"
        case .settings:
            return "Settings"
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .params:
            KVEditorView(
                items: $draft.params,
                keyPlaceholder: "query_param",
                valuePlaceholder: "value",
                emptyLabel: "No query parameters."
            )

        case .headers:
            let inheritedCount = HttpClientLogic.inheritedEnabledHeaderCount(bundle: bundle, folderId: draft.folderId)
            VStack(alignment: .leading, spacing: 12) {
                if inheritedCount > 0 {
                    Text("Inherits \(inheritedCount) workspace/folder header(s). Matching keys below override them.")
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(HttpStyle.sidebarBackground(theme), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
                }
                KVEditorView(
                    items: $draft.headers,
                    keyPlaceholder: "Header-Name",
                    valuePlaceholder: "value",
                    emptyLabel: "No request-specific headers."
                )
            }

        case .auth:
            let inherited = HttpClientLogic.resolveInheritedAuth(bundle: bundle, folderId: draft.folderId)
            AuthEditorView(
                value: $draft.auth,
                allowInherit: true,
                inheritedSummary: "Inheriting from \(inherited.label)",
                secrets: secrets
            )

        case .body:
            bodyTab

        case .settings:
            settingsTab
        }
    }

    // MARK: - Body Tab

    private var bodyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("Body mode", selection: $draft.bodyMode) {
                    ForEach(HttpBodyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200, alignment: .leading)

                Spacer(minLength: 8)

                if draft.bodyMode == .json {
                    Button("Format JSON") {
                        if let formatted = HttpClientLogic.formatJSON(draft.body) {
                            draft.body = formatted
                        } else {
                            context.showToast(
                                ToastItemModel(
                                    id: "http.format-json",
                                    title: "Body is not valid JSON",
                                    tone: .error
                                )
                            )
                        }
                    }
                    .buttonStyle(.vesper())
                }
            }

            switch draft.bodyMode {
            case .none:
                Text("This request does not send a body.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.tertiaryText)

            case .json, .raw:
                ZStack(alignment: .topLeading) {
                    if draft.body.isEmpty {
                        Text(draft.bodyMode == .json ? "{\n  \"key\": \"value\"\n}" : "Raw body\u{2026}")
                            .font(theme.font(.mono))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft.body)
                        .font(theme.font(.mono))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 240)
                }
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))

            case .formUrlencoded, .multipart:
                KVEditorView(
                    items: $draft.bodyForm,
                    keyPlaceholder: "field",
                    valuePlaceholder: "value",
                    emptyLabel: "No form fields."
                )
            }
        }
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Follow HTTP redirects (SSRF-checked per hop)", isOn: $draft.followRedirects)
                .vesperText(.body, theme)

            HttpField(
                label: "Timeout (ms)",
                hint: "Valid range: \(HttpClientLogic.minTimeoutMs)–\(HttpClientLogic.maxTimeoutMs) ms (default \(HttpClientLogic.defaultTimeoutMs) ms)"
            ) {
                HStack(spacing: 10) {
                    TextField("30000", text: $timeoutText)
                        .httpInputBox(theme, mono: true)
                        .frame(width: 140)
                        .onChange(of: timeoutText) { _, next in
                            let filtered = next.filter(\.isNumber)
                            if filtered != next {
                                timeoutText = filtered
                                return
                            }
                            if let parsed = Int(filtered) {
                                draft.timeoutMs = parsed
                            } else if filtered.isEmpty {
                                draft.timeoutMs = HttpClientLogic.defaultTimeoutMs
                            }
                        }

                    let clamped = HttpClientLogic.clampTimeoutMs(draft.timeoutMs)
                    if clamped != draft.timeoutMs {
                        Text("Effective: \(clamped) ms")
                            .vesperText(.small, theme)
                            .foregroundStyle(theme.swiftUIColor("state-human", fallback: .orange))
                    }
                }
            }
        }
    }
}
