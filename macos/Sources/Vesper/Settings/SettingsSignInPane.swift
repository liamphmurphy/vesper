import SwiftUI
import VesperCore

struct SettingsSignInPane: View {
    let aux: AuxWindows

    @State private var status: OwnerAuthStatus?
    @State private var loading = false
    @State private var loadError: String?
    @State private var loginText = ""
    @State private var passwordText = ""
    @State private var fieldError: (field: OwnerAuthField?, message: String)?
    @State private var submitting = false
    @State private var savedNotice: String?

    var body: some View {
        SettingsScrollContainer {
            SettingsPaneHeader(
                "Sign-in",
                subtitle: "Owner username and password for signing in to Vesper from another browser or device."
            )

            if loading && status == nil {
                SettingsCard {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking sign-in status…").foregroundStyle(.secondary)
                    }
                }
            } else if let loadError, status == nil {
                SettingsBanner(tone: .blocked, title: "Couldn't load sign-in status", message: loadError) {
                    Button("Retry") { Task { await refresh() } }
                }
            } else if let status {
                SettingsCard("Status") {
                    HStack(spacing: 8) {
                        SettingsBadge(
                            label: status.passwordSet ? "Password is set" : "No password set",
                            tone: status.passwordSet ? .done : .neutral
                        )
                        SettingsBadge(
                            label: status.claimed ? "Claimed" : "Unclaimed",
                            tone: status.claimed ? .done : .human
                        )
                        Spacer()
                        Button("Refresh") { Task { await refresh() } }
                    }
                    Text(status.passwordSet
                         ? "Other browsers sign in at /signin with your owner username and password, or with a temporary sign-in link from `make signin`."
                         : "Set an owner username and password below so another browser can sign in.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                SettingsCard(status.passwordSet ? "Password recovery" : "Set owner password") {
                    if let savedNotice {
                        SettingsBanner(tone: .done, title: savedNotice)
                    }
                    if status.passwordSet {
                        Text("Your owner password is already configured on this instance. To replace a forgotten password or recover access from a terminal, run:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("make signin")
                                .font(.callout.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                            Button("Copy") { SettingsFilePanels.copyToPasteboard("make signin") }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Username (letters, digits, . _ @ -)", text: $loginText)
                                .textFieldStyle(.roundedBorder)
                            if let err = fieldError, err.field == .login {
                                Text(err.message).font(.caption).foregroundStyle(.red)
                            }
                            SecureField("Password (8 to 256 characters)", text: $passwordText)
                                .textFieldStyle(.roundedBorder)
                            if let err = fieldError, err.field == .password {
                                Text(err.message).font(.caption).foregroundStyle(.red)
                            }
                            if let err = fieldError, err.field == nil {
                                Text(err.message).font(.caption).foregroundStyle(.red)
                            }
                            HStack {
                                Spacer()
                                Button(submitting ? "Saving…" : "Set Username & Password") {
                                    submitSetup()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(submitting || loginText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || passwordText.isEmpty)
                            }
                        }
                    }
                }
            } else {
                SettingsCard {
                    Text("Start Vesper to configure owner sign-in.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        guard let client = aux.client() else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            status = try await OwnerAuthAPI.status(using: client)
        } catch {
            loadError = settingsErrorText(error)
        }
    }

    private func submitSetup() {
        guard let client = aux.client() else { return }
        fieldError = nil
        savedNotice = nil
        submitting = true
        let login = loginText
        let pw = passwordText
        Task {
            defer { submitting = false }
            let result = await OwnerAuthAPI.setup(login: login, password: pw, using: client)
            switch result {
            case .success(let updated):
                status = updated
                passwordText = ""
                savedNotice = "Owner password saved."
            case .failure(let message, let field):
                fieldError = (field, message)
            }
        }
    }
}
