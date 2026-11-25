import SwiftUI
import VesperCore

/// Native `/setup` onboarding screen: display name / primary email editor and live setup checklist.
struct SetupScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var nameDraft = ""
    @State private var roleDraft = ""
    @State private var emailDraft = ""
    @State private var hydrated = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var savedBanner: String?

    private static let bootRequest = API.getBootstrap()
    private static let modelsRequest = API.listChatModels()
    private static let runnerRequest = API.getRunnerStatus()
    private static let spacesRequest = API.listChatSpaces()
    private static let secretsRequest = API.listSecrets()

    var body: some View {
        let p = theme.palette
        let boot = context.store.entry(Self.bootRequest).data
        let models = context.store.entry(Self.modelsRequest).data ?? []
        let runner = context.store.entry(Self.runnerRequest).data
        let spaces = context.store.entry(Self.spacesRequest).data?.spaces ?? []
        let secrets = context.store.entry(Self.secretsRequest).data?.secrets ?? []

        let me = boot?.me
        let ready = me.map { !LandingLogic.needsProfileSetup(name: $0.name, email: $0.email) } ?? false
        let reposCount = spaces.filter { $0.work?.repoUrl != nil && !($0.work?.repoUrl?.isEmpty ?? true) }.count
        let firstWorkSpaceId = spaces.first(where: { $0.work != nil })?.id
        let harnessSecretSet = secrets.contains { $0.name.hasPrefix("harness:") && $0.project == nil }
        let checklist = WorkspaceSetupHelpers.checklist(
            reposCount: reposCount,
            firstWorkSpaceId: firstWorkSpaceId,
            harnessSecretSet: harnessSecretSet,
            harnessModels: models,
            runner: runner
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Get started with Vesper")
                        .vesperText(.display, theme)
                    Text("Set your display name and primary email first. Agents author commits with your primary email; coding chats can use any address in your profile.")
                        .vesperText(.body, theme)
                        .foregroundStyle(p.secondaryText)
                }

                // Profile card
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your profile")
                        .vesperText(.heading, theme)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Display name")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(p.secondaryText)
                        TextField("Your name", text: $nameDraft)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Primary email")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(p.secondaryText)
                        TextField("you@example.com", text: $emailDraft)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Role (optional)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(p.secondaryText)
                        TextField("e.g. Staff Engineer", text: $roleDraft)
                            .textFieldStyle(.roundedBorder)
                    }

                    if let saveError {
                        Text(saveError)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    }
                    if let savedBanner {
                        Text(savedBanner)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                    }

                    HStack {
                        Spacer()
                        Button(saving ? "Saving\u{2026}" : "Save profile") {
                            saveProfile(me: me)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || emailDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(18)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))

                Text("Your Assistant starts with all persona permissions enabled. Connect a provider to chat; repositories and agents can be added whenever you need them.")
                    .vesperText(.body, theme)
                    .foregroundStyle(p.secondaryText)

                // Live checklist
                VStack(alignment: .leading, spacing: 10) {
                    Text("Workspace checklist")
                        .vesperText(.heading, theme)

                    ForEach(checklist) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(item.done ? theme.swiftUIColor("state-done", fallback: .green) : p.tertiaryText)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(p.text)
                                Text(item.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.secondaryText)
                            }
                            Spacer()
                            Button(item.linkLabel) {
                                context.navigate(item.href)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(12)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                    }
                }

                if ready {
                    Button("Continue to chat") {
                        context.navigate("/chat?new")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Replace the placeholder name and primary email, then save your profile to continue.")
                        .font(.system(size: 13))
                        .foregroundStyle(p.secondaryText)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            context.chrome = NativeChrome(
                title: "Get started"
            )
            context.store.load(Self.bootRequest)
            context.store.load(Self.modelsRequest)
            context.store.load(Self.runnerRequest)
            context.store.load(Self.spacesRequest)
            context.store.load(Self.secretsRequest)
            hydrateIfNeeded(me: me)
        }
        .onChange(of: me?.id) { _, _ in
            hydrateIfNeeded(me: me)
        }
    }

    private func hydrateIfNeeded(me: API.User?) {
        guard !hydrated, let me else { return }
        hydrated = true
        nameDraft = me.name == "Local user" ? "" : me.name
        roleDraft = me.roleTitle
        emailDraft = ["me@localhost", "me@localhost.com"].contains(me.email.lowercased()) ? "" : me.email
    }

    private func saveProfile(me: API.User?) {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = emailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = roleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else { return }
        var emails = me?.emails?.filter { $0.caseInsensitiveCompare(email) != .orderedSame } ?? []
        emails.insert(email, at: 0)
        saving = true
        saveError = nil
        savedBanner = nil
        Task {
            defer { saving = false }
            do {
                _ = try await context.store.mutate(
                    API.updateProfile(body: API.ProfilePatch(emails: emails, name: name, roleTitle: role)),
                    invalidating: QueryInvalidation(resources: ["bootstrap", "profile"])
                )
                _ = await context.store.refetch(Self.bootRequest)
                savedBanner = "Profile saved."
            } catch {
                saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
