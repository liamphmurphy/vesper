import SwiftUI
import VesperCore

struct SettingsYouPane: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation

    @State private var name = ""
    @State private var roleTitle = ""
    @State private var emails: [String] = []
    @State private var newEmail = ""
    @State private var loadedUserId: String?
    @State private var saving = false
    @State private var avatarBusy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let entry = store?.entry(API.getProfile())
        SettingsScrollContainer {
            SettingsPaneHeader(
                "You",
                subtitle: "How personas refer to you, commit authorship addresses, and your profile photo."
            )

            if let user = entry?.data {
                SettingsCard("Profile") {
                    HStack(alignment: .center, spacing: 14) {
                        SettingsAvatarView(
                            avatarURL: user.avatarUrl,
                            initials: user.initials,
                            colorHex: user.avatarColor,
                            size: 56
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            Text(user.name).font(.headline)
                            Text(PersonaUIHelpers.avatarHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button(avatarBusy ? "Uploading…" : (user.avatarUrl == nil ? "Upload Photo…" : "Change Photo…")) {
                                    uploadAvatar()
                                }
                                .disabled(avatarBusy)
                                if user.avatarUrl != nil {
                                    Button("Remove Photo") { removeAvatar() }
                                        .disabled(avatarBusy)
                                }
                            }
                        }
                        Spacer()
                    }
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Name").foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                            TextField("Your name", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Role / title").foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                            TextField("e.g. Engineer (optional)", text: $roleTitle)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Email addresses")
                            .font(.subheadline.weight(.medium))
                        Text("The first address is primary and used as default git commit author.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(emails.enumerated()), id: \.offset) { idx, addr in
                            HStack(spacing: 8) {
                                Text(addr).font(.callout.monospaced())
                                if idx == 0 {
                                    SettingsBadge(label: "Primary", tone: .done)
                                }
                                Spacer()
                                if idx > 0 {
                                    Button("Make Primary") {
                                        var updated = emails
                                        let moved = updated.remove(at: idx)
                                        updated.insert(moved, at: 0)
                                        emails = updated
                                    }
                                    .buttonStyle(.borderless)
                                }
                                if emails.count > 1 {
                                    Button("Remove") {
                                        emails.remove(at: idx)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            TextField("Add email address", text: $newEmail)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { appendEmail() }
                            Button("Add") { appendEmail() }
                                .disabled(newEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    HStack {
                        if let statusMessage {
                            Text(statusMessage).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(saving ? "Saving…" : "Save Profile") {
                            saveProfile()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { syncDraft(from: user) }
                .onChange(of: user) { _, next in
                    if loadedUserId != next.id { syncDraft(from: next) }
                }
            } else if entry?.isFetching == true {
                SettingsCard {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading profile…").foregroundStyle(.secondary)
                    }
                }
            } else {
                SettingsUnavailableCard(title: "Couldn't load profile", error: entry?.error) {
                    Task { await store?.refetch(API.getProfile()) }
                }
            }

            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Couldn't save profile", message: errorMessage)
            }

            SettingsCard("Memory", subtitle: "What the Personal Assistant remembers about you.") {
                HStack {
                    Text("View, add, edit, import, or export your saved memories.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Memory") {
                        navigation.selection = .memory
                    }
                }
            }
        }
        .task {
            if let entry = store?.load(API.getProfile()), let user = entry.data {
                syncDraft(from: user)
            }
        }
    }

    private func syncDraft(from user: API.User) {
        loadedUserId = user.id
        name = user.name
        roleTitle = user.roleTitle
        emails = user.emails ?? (user.email.isEmpty ? [] : [user.email])
    }

    private func appendEmail() {
        let trimmed = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !emails.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            emails.append(trimmed)
        }
        newEmail = ""
    }

    private func saveProfile() {
        guard let store else { return }
        errorMessage = nil
        statusMessage = nil
        saving = true
        let patch = API.ProfilePatch(
            emails: emails.isEmpty ? nil : emails,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            roleTitle: roleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        Task {
            defer { saving = false }
            do {
                let updated = try await store.mutate(API.updateProfile(body: patch))
                store.setData(updated, for: API.getProfile())
                syncDraft(from: updated)
                statusMessage = "Profile saved."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func uploadAvatar() {
        guard let client = aux.client(), let store else { return }
        guard let picked = SettingsFilePanels.openImageForAvatar() else { return }
        if let err = PersonaUIHelpers.validateAvatarData(picked.data, fileName: picked.fileName, contentType: picked.mimeType) {
            errorMessage = err
            return
        }
        errorMessage = nil
        statusMessage = nil
        avatarBusy = true
        var form = APIMultipartForm()
        form.addFile("file", filename: picked.fileName, contentType: picked.mimeType.isEmpty ? "application/octet-stream" : picked.mimeType, data: picked.data)
        Task {
            defer { avatarBusy = false }
            do {
                let updated = try await client.send(API.uploadProfileAvatar(body: form))
                store.setData(updated, for: API.getProfile())
                statusMessage = "Photo updated."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func removeAvatar() {
        guard let store else { return }
        errorMessage = nil
        statusMessage = nil
        avatarBusy = true
        Task {
            defer { avatarBusy = false }
            do {
                let updated = try await store.mutate(API.deleteProfileAvatar())
                store.setData(updated, for: API.getProfile())
                statusMessage = "Photo removed."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}
