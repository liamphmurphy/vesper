import SwiftUI
import VesperCore

struct SettingsMailPane: View {
    let aux: AuxWindows

    @State private var loaded = false
    @State private var enabled = false
    @State private var dryRun = true
    @State private var email = ""
    @State private var password = ""
    @State private var imapHost = "imap.mail.me.com"
    @State private var imapPort = "993"
    @State private var carddavUrl = "https://contacts.icloud.com/"
    @State private var defaultFolder = "Low Priority"
    @State private var allowedFoldersText = "Low Priority, Newsletters, Receipts"
    @State private var pinnedModel = ""
    @State private var pollIntervalSeconds = "60"
    @State private var triagePolicy = ""
    @State private var defaultPolicyHint = ""

    @State private var newRuleName = ""
    @State private var newRuleField = API.NewMailRule.MatchField.fromDomain
    @State private var newRuleValue = ""
    @State private var newRuleAction = API.NewMailRule.Action.move
    @State private var newRuleFolder = "Low Priority"

    @State private var busy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var testSummary: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let acctEntry = store?.entry(API.getMailAccount())
        let rulesEntry = store?.entry(API.listMailRules())
        let logEntry = store?.entry(API.listMailTriageLog(limit: 40))

        let resp = acctEntry?.data
        let acct = resp?.account?.value
        let rules = rulesEntry?.data?.rules ?? []
        let logEntries = logEntry?.data?.entries ?? []

        SettingsScrollContainer {
            SettingsPaneHeader(
                "Mail Butler",
                subtitle: "Opt-in background IMAP/CardDAV organizer for iCloud Mail. Keeps Apple Contacts and important notices in Inbox, files noise into folders synced to Apple Mail, and uses an idle VM with your default persona's fast model for unknown senders."
            ) {
                Button(busy ? "Saving…" : "Save") {
                    Task { await saveAccount() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Mail Butler error", message: errorMessage)
            }
            if let statusMessage {
                SettingsBanner(tone: .done, title: statusMessage)
            }
            if let testSummary {
                SettingsBanner(tone: .done, title: "Connection test", message: testSummary)
            }

            SettingsCard("Status & Safety (Opt-in)") {
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Mail Butler")
                        Text("Off by default. When enabled, Vesper polls INBOX, syncs Apple Contacts over CardDAV, and exposes mail_* tools in chat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $dryRun) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dry-Run Mode")
                        Text("Logs every decision without moving messages in IMAP. Recommended for your first day.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let acct {
                    Divider()
                    HStack(spacing: 16) {
                        Label("\(acct.contactsCount) Apple Contacts synced", systemImage: "person.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label("\(acct.pendingTriageCount) queued for idle VM", systemImage: "tray.full")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !acct.lastError.isEmpty {
                        Text("Last sync error: \(acct.lastError)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            SettingsCard("iCloud Account") {
                LabeledContent("Apple ID / iCloud Email") {
                    TextField("you@icloud.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("App-Specific Password") {
                    SecureField(
                        acct == nil ? "xxxx-xxxx-xxxx-xxxx" : "Leave blank to keep stored password",
                        text: $password
                    )
                    .textFieldStyle(.roundedBorder)
                }
                Text("Generate at appleid.apple.com → Sign-In and Security → App-Specific Passwords. Stored encrypted at rest (AES-256-GCM) and never shared with VMs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Server settings (iCloud defaults)") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("IMAP Host") {
                            TextField("imap.mail.me.com", text: $imapHost)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("IMAP Port") {
                            TextField("993", text: $imapPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }
                        LabeledContent("CardDAV URL") {
                            TextField("https://contacts.icloud.com/", text: $carddavUrl)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Poll Interval (seconds)") {
                            TextField("60", text: $pollIntervalSeconds)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }
                    }
                    .padding(.top, 6)
                }

                if acct != nil {
                    HStack(spacing: 10) {
                        Button("Test Connection") {
                            Task { await testConnection() }
                        }
                        .disabled(busy)

                        Button("Sync Contacts Now") {
                            Task { await syncContacts() }
                        }
                        .disabled(busy)

                        Spacer()

                        Button("Remove Account", role: .destructive) {
                            Task { await deleteAccount() }
                        }
                        .disabled(busy)
                    }
                    .padding(.top, 4)
                }
            }

            SettingsCard("Folders, Model & Triage Policy") {
                LabeledContent("Default Non-Important Folder") {
                    TextField("Low Priority", text: $defaultFolder)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Allowed Target Folders") {
                    TextField("Low Priority, Newsletters, Receipts", text: $allowedFoldersText)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Pinned Fast Model (optional)") {
                    TextField("Auto-pick from default persona", text: $pinnedModel)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Leave blank to auto-pick the fast model for your default persona's harness, or pin a specific model ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Plain-English Triage Policy")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if !defaultPolicyHint.isEmpty {
                        Button("Use Default") {
                            triagePolicy = defaultPolicyHint
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 4)

                TextEditor(text: $triagePolicy)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }

            if acct != nil {
                SettingsCard("Deterministic Rules (Checked Before LLM)") {
                    HStack(spacing: 8) {
                        Picker("", selection: $newRuleField) {
                            Text("From email").tag(API.NewMailRule.MatchField.fromEmail)
                            Text("From domain").tag(API.NewMailRule.MatchField.fromDomain)
                            Text("Subject").tag(API.NewMailRule.MatchField.subject)
                            Text("List-Id").tag(API.NewMailRule.MatchField.listId)
                        }
                        .labelsHidden()
                        .frame(width: 120)

                        TextField("e.g. substack.com", text: $newRuleValue)
                            .textFieldStyle(.roundedBorder)

                        Picker("", selection: $newRuleAction) {
                            Text("Move").tag(API.NewMailRule.Action.move)
                            Text("Keep").tag(API.NewMailRule.Action.keep)
                        }
                        .labelsHidden()
                        .frame(width: 80)

                        if newRuleAction == .move {
                            TextField("Folder", text: $newRuleFolder)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 130)
                        }

                        Button("Add") {
                            Task { await createRule() }
                        }
                        .disabled(busy || newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if rules.isEmpty {
                        Text("No explicit rules yet. Anyone in Apple Contacts is automatically kept in INBOX.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(rules, id: \.id) { rule in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.name.isEmpty ? "\(rule.matchField.rawValue): \(rule.matchValue)" : rule.name)
                                        .font(.callout.weight(.medium))
                                    Text("\(rule.matchField.rawValue) = \(rule.matchValue) → \(rule.action.rawValue)\(rule.targetFolder.isEmpty ? "" : " (\(rule.targetFolder))")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    Task { await deleteRule(rule.id) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .disabled(busy)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                SettingsCard("Recent Triage Log") {
                    if logEntries.isEmpty {
                        Text("No triage activity recorded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(logEntries, id: \.id) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(entry.subject.isEmpty ? "(No subject)" : entry.subject)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                        Text(entry.tier.rawValue.uppercased())
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.15), in: Capsule())
                                        if entry.dryRun {
                                            Text("DRY RUN")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.2), in: Capsule())
                                        }
                                        if entry.undoneAt?.value != nil {
                                            Text("UNDONE")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text("\(entry.fromEmail) • \(entry.action.rawValue)\(entry.targetFolder.isEmpty ? "" : " → \(entry.targetFolder)") — \(entry.reason)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                if entry.action.rawValue == "move" && entry.undoneAt?.value == nil {
                                    Menu("Undo") {
                                        Button("Move back to Inbox") {
                                            Task { await undoEntry(entry.id, pinSender: false) }
                                        }
                                        Button("Move back & always keep sender") {
                                            Task { await undoEntry(entry.id, pinSender: true) }
                                        }
                                    }
                                    .controlSize(.small)
                                    .disabled(busy)
                                }
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
            }
        }
        .onAppear {
            if let resp {
                syncForm(from: resp)
            }
        }
        .onChange(of: resp) { _, newResp in
            if let newResp, !loaded {
                syncForm(from: newResp)
            }
        }
    }

    private func syncForm(from resp: API.MailAccountResponse) {
        loaded = true
        defaultPolicyHint = resp.defaultTriagePolicy
        if let acct = resp.account?.value {
            enabled = acct.enabled
            dryRun = acct.dryRun
            email = acct.email
            imapHost = acct.imapHost
            imapPort = String(acct.imapPort)
            carddavUrl = acct.carddavUrl
            defaultFolder = acct.defaultFolder
            allowedFoldersText = acct.allowedFolders.joined(separator: ", ")
            pinnedModel = acct.pinnedModel
            pollIntervalSeconds = String(acct.pollIntervalSeconds)
            triagePolicy = acct.triagePolicy.isEmpty ? resp.defaultTriagePolicy : acct.triagePolicy
        } else if triagePolicy.isEmpty {
            triagePolicy = resp.defaultTriagePolicy
        }
    }

    private func saveAccount() async {
        guard let store else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        defer { busy = false }
        do {
            let folders = allowedFoldersText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let body = API.UpsertMailAccount(
                allowedFolders: folders.isEmpty ? nil : folders,
                carddavUrl: carddavUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                defaultFolder: defaultFolder.trimmingCharacters(in: .whitespacesAndNewlines),
                dryRun: dryRun,
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                enabled: enabled,
                imapHost: imapHost.trimmingCharacters(in: .whitespacesAndNewlines),
                imapPort: Int(imapPort),
                password: password.isEmpty ? nil : password,
                pinnedModel: pinnedModel.trimmingCharacters(in: .whitespacesAndNewlines),
                pollIntervalSeconds: Int(pollIntervalSeconds),
                triagePolicy: triagePolicy
            )
            _ = try await store.mutate(
                API.upsertMailAccount(body: body),
                invalidating: QueryInvalidation(resources: ["mail"])
            )
            password = ""
            statusMessage = enabled
                ? (dryRun ? "Saved — Mail Butler enabled in Dry-Run mode." : "Saved — Mail Butler enabled (Live).")
                : "Saved — Mail Butler is currently disabled."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testConnection() async {
        guard let store else { return }
        busy = true
        errorMessage = nil
        testSummary = nil
        defer { busy = false }
        do {
            let res = try await store.mutate(API.testMailAccount(), invalidating: QueryInvalidation())
            let imapPart = res.imapOk ? "IMAP OK" : "IMAP failed: \(res.imapError)"
            let cardPart = res.carddavOk ? "CardDAV OK (\(res.contactsCount) contacts)" : "CardDAV failed: \(res.carddavError)"
            testSummary = "\(imapPart) • \(cardPart)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncContacts() async {
        guard let store else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        defer { busy = false }
        do {
            let res = try await store.mutate(
                API.syncMailContacts(),
                invalidating: QueryInvalidation(resources: ["mail"])
            )
            statusMessage = "Synced \(res.contactsCount) Apple Contacts."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAccount() async {
        guard let store else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        defer { busy = false }
        do {
            _ = try await store.mutate(
                API.deleteMailAccount(),
                invalidating: QueryInvalidation(resources: ["mail"])
            )
            loaded = false
            enabled = false
            dryRun = true
            email = ""
            password = ""
            statusMessage = "Mail Butler account removed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createRule() async {
        guard let store else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        defer { busy = false }
        do {
            let body = API.NewMailRule(
                action: newRuleAction,
                enabled: true,
                matchField: newRuleField,
                matchValue: newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines),
                name: newRuleName.isEmpty ? nil : newRuleName,
                priority: 100,
                targetFolder: newRuleAction == .move ? newRuleFolder.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            )
            _ = try await store.mutate(
                API.createMailRule(body: body),
                invalidating: QueryInvalidation(resources: ["mail"])
            )
            newRuleValue = ""
            newRuleName = ""
            statusMessage = "Rule added."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRule(_ id: String) async {
        guard let store else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            _ = try await store.mutate(
                API.deleteMailRule(id: id),
                invalidating: QueryInvalidation(resources: ["mail"])
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func undoEntry(_ id: String, pinSender: Bool) async {
        guard let store else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        defer { busy = false }
        do {
            _ = try await store.mutate(
                API.undoMailTriageLog(id: id, body: API.UndoMailTriageRequest(pinSender: pinSender)),
                invalidating: QueryInvalidation(resources: ["mail"])
            )
            statusMessage = pinSender ? "Moved back to Inbox and pinned sender." : "Moved back to Inbox."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
