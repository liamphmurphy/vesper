import SwiftUI
import VesperCore

struct AuthEditorView: View {
    @Environment(\.vesperTheme) private var theme
    @Binding var value: HttpAuthConfig
    let allowInherit: Bool
    var inheritedSummary: String? = nil
    var secrets: [API.ApiSecret] = []

    @State private var showBasicPassword = false
    @State private var showOAuthSecret = false

    private var options: [HttpAuthType] {
        allowInherit ? HttpAuthType.allCases : HttpAuthType.allCases.filter { $0 != .inherit }
    }

    private var typeBinding: Binding<HttpAuthType> {
        Binding(
            get: { value.type },
            set: { nextType in
                var updated = value
                updated.type = nextType
                if nextType == .oauth2 && updated.oauth2 == nil {
                    updated.oauth2 = HttpOAuth2Config()
                } else if nextType == .apikey {
                    if updated.apiKeyIn == nil { updated.apiKeyIn = .header }
                    if updated.apiKeyName == nil { updated.apiKeyName = "X-API-Key" }
                }
                value = updated
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HttpField(label: "Authentication method") {
                Picker("Authentication method", selection: typeBinding) {
                    ForEach(options) { option in
                        Text(HttpClientLogic.authLabel(option)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            switch value.type {
            case .inherit:
                Text(inheritedSummary ?? "Inherits authentication from its parent folder or workspace.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(HttpStyle.sidebarBackground(theme), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))

            case .none:
                Text("No authentication will be added to outgoing requests.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.tertiaryText)

            case .bearer:
                HttpField(
                    label: "Bearer token",
                    hint: "Supports {{variable}} or {{secret:handle}} placeholders"
                ) {
                    HStack(spacing: 6) {
                        TextField(
                            "{{api_token}}",
                            text: Binding(
                                get: { value.token ?? "" },
                                set: { value.token = $0 }
                            )
                        )
                        .httpInputBox(theme, mono: true)
                        secretMenu { handle in
                            value.token = "{{secret:\(handle)}}"
                        }
                    }
                }

            case .basic:
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        basicUsernameField
                        basicPasswordField
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        basicUsernameField
                        basicPasswordField
                    }
                }

            case .apikey:
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        apiKeyNameField
                        apiKeyValueField
                        apiKeyPlacementField
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        apiKeyNameField
                        apiKeyValueField
                        apiKeyPlacementField
                    }
                }

            case .oauth2:
                oauth2Fields
            }
        }
    }

    // MARK: - Basic Auth

    private var basicUsernameField: some View {
        HttpField(label: "Username") {
            TextField(
                "{{basic_user}}",
                text: Binding(
                    get: { value.username ?? "" },
                    set: { value.username = $0 }
                )
            )
            .httpInputBox(theme, mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var basicPasswordField: some View {
        HttpField(label: "Password") {
            HStack(spacing: 6) {
                secretInput(
                    placeholder: "{{basic_pass}}",
                    text: Binding(
                        get: { value.password ?? "" },
                        set: { value.password = $0 }
                    ),
                    revealed: $showBasicPassword
                )
                secretMenu { handle in
                    value.password = "{{secret:\(handle)}}"
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - API Key Auth

    private var apiKeyNameField: some View {
        HttpField(label: "Key name") {
            TextField(
                "X-API-Key",
                text: Binding(
                    get: { value.apiKeyName ?? "" },
                    set: { value.apiKeyName = $0 }
                )
            )
            .httpInputBox(theme, mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var apiKeyValueField: some View {
        HttpField(label: "Value") {
            HStack(spacing: 6) {
                TextField(
                    "{{api_key}}",
                    text: Binding(
                        get: { value.apiKeyValue ?? "" },
                        set: { value.apiKeyValue = $0 }
                    )
                )
                .httpInputBox(theme, mono: true)
                secretMenu { handle in
                    value.apiKeyValue = "{{secret:\(handle)}}"
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var apiKeyPlacementField: some View {
        HttpField(label: "Placement") {
            Picker(
                "API key placement",
                selection: Binding(
                    get: { value.apiKeyIn ?? .header },
                    set: { value.apiKeyIn = $0 }
                )
            ) {
                Text("Header").tag(HttpAPIKeyPlacement.header)
                Text("Query parameter").tag(HttpAPIKeyPlacement.query)
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    // MARK: - OAuth 2.0

    private var oauth2Fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HttpField(
                label: "Access token URL",
                hint: "External HTTPS token endpoint (supports {{base_url}})"
            ) {
                TextField(
                    "{{auth_url}}/oauth/token",
                    text: oauthBinding(\.tokenUrl)
                )
                .httpInputBox(theme, mono: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    oauthClientIdField
                    oauthClientSecretField
                }
                VStack(alignment: .leading, spacing: 12) {
                    oauthClientIdField
                    oauthClientSecretField
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    oauthScopeField
                    oauthAudienceField
                }
                VStack(alignment: .leading, spacing: 12) {
                    oauthScopeField
                    oauthAudienceField
                }
            }
        }
    }

    private var oauthClientIdField: some View {
        HttpField(label: "Client ID") {
            TextField("{{oauth_client_id}}", text: oauthBinding(\.clientId))
                .httpInputBox(theme, mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var oauthClientSecretField: some View {
        HttpField(label: "Client Secret") {
            HStack(spacing: 6) {
                secretInput(
                    placeholder: "{{oauth_client_secret}}",
                    text: oauthBinding(\.clientSecret),
                    revealed: $showOAuthSecret
                )
                secretMenu { handle in
                    var oauth = value.oauth2 ?? HttpOAuth2Config()
                    oauth.grantType = "client_credentials"
                    oauth.clientSecret = "{{secret:\(handle)}}"
                    value.oauth2 = oauth
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var oauthScopeField: some View {
        HttpField(label: "Scope (optional)") {
            TextField("read:all", text: oauthBinding(\.scope))
                .httpInputBox(theme, mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var oauthAudienceField: some View {
        HttpField(label: "Audience (optional)") {
            TextField("https://api.example.com", text: oauthBinding(\.audience))
                .httpInputBox(theme, mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func oauthBinding(_ keyPath: WritableKeyPath<HttpOAuth2Config, String>) -> Binding<String> {
        Binding(
            get: { (value.oauth2 ?? HttpOAuth2Config())[keyPath: keyPath] },
            set: { newValue in
                var oauth = value.oauth2 ?? HttpOAuth2Config()
                oauth.grantType = "client_credentials"
                oauth[keyPath: keyPath] = newValue
                value.oauth2 = oauth
            }
        )
    }

    // MARK: - Helpers

    @ViewBuilder
    private func secretInput(placeholder: String, text: Binding<String>, revealed: Binding<Bool>) -> some View {
        HStack(spacing: 4) {
            Group {
                if revealed.wrappedValue {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(theme.font(.mono))

            Button {
                revealed.wrappedValue.toggle()
            } label: {
                Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed.wrappedValue ? "Hide value" : "Reveal value")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
    }

    @ViewBuilder
    private func secretMenu(onPick: @escaping (String) -> Void) -> some View {
        if !secrets.isEmpty {
            Menu {
                ForEach(secrets, id: \.id) { secret in
                    Button("secret:\(secret.handle) (\(secret.name))") {
                        onPick(secret.handle)
                    }
                }
            } label: {
                Image(systemName: "key")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Insert Vesper secret placeholder")
        }
    }
}
