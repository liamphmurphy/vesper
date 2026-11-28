import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

/// First-run Welcome Wizard hosted by the default Assistant inside `/chat`.
/// Walks a new user through:
/// 0. Greeting
/// 1. About you (profile name, role/work memory, optional email & photo)
/// 2. Connect a harness (Claude Code, Codex, Antigravity via native Sign-In or key/login + Verify)
/// 3. Tour of Vesper's default apps (Chat, Spaces, Knowledge, Library, Browser, Apps & Tools)
/// 4. Your first persona (natural-language drafting and iterative refinement with the default Assistant)
///
/// When `mode == .harnessOnly` (already onboarded, but no harness is currently connected), only step 2
/// is shown and `onDone(nil)` hands straight back to Chat once verified.
struct WelcomeWizardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let mode: OnboardingLogic.WizardMode
    @Binding var step: OnboardingLogic.WizardStep
    let onDone: @MainActor (String?) -> Void

    @State private var verifiedHarnesses: [API.Harness: Int] = [:]
    @State private var hour: Int = Calendar.current.component(.hour, from: Date())
    @State private var breathe = false

    private static let personasRequest = API.listPersonas()
    private static let modelsRequest = API.listChatModels()
    private static let secretsRequest = API.listSecrets()
    private static let bootRequest = API.getBootstrap()

    var body: some View {
        let p = theme.palette
        let personasList = context.store.entry(Self.personasRequest).data
        let host = resolveHost(from: personasList)
        let line = OnboardingLogic.assistantLine(step: step, mode: mode, hour: hour)
        let verifiedOrdered = OnboardingLogic.harnessCards.map(\.harness).filter { verifiedHarnesses[$0] != nil }

        ScrollView {
            VStack(spacing: 0) {
                hostPortrait(host: host, palette: p)
                    .padding(.top, 28)

                Text(host?.name ?? "Assistant")
                    .font(.system(size: 24 * theme.typeScale, weight: .semibold))
                    .foregroundStyle(p.text)
                    .padding(.top, 14)

                WizardSaidLine(text: line)
                    .id(line)
                    .padding(.top, 6)

                if mode == .full && step != .greeting {
                    stepProgressHeader(palette: p)
                        .padding(.top, 18)
                }

                VStack(alignment: .leading, spacing: 0) {
                    switch step {
                    case .greeting:
                        WelcomeGreetingStep {
                            advance(to: .aboutYou)
                        }
                    case .aboutYou:
                        WelcomeAboutYouStep(
                            onBack: { advance(to: .greeting) },
                            onNext: { advance(to: .connectHarness) }
                        )
                    case .connectHarness:
                        WelcomeConnectHarnessStep(
                            harnessOnly: mode == .harnessOnly,
                            verified: $verifiedHarnesses,
                            onBack: mode == .full ? { advance(to: .aboutYou) } : nil,
                            onSkip: mode == .full ? { advance(to: .appTour) } : nil,
                            onNext: {
                                Task { _ = await context.store.refetch(Self.modelsRequest) }
                                if mode == .harnessOnly {
                                    Task {
                                        _ = await context.store.refetch(Self.bootRequest)
                                        onDone(nil)
                                    }
                                } else {
                                    advance(to: .appTour)
                                }
                            }
                        )
                    case .appTour:
                        WelcomeAppTourStep(
                            onBack: { advance(to: .connectHarness) },
                            onNext: { advance(to: .firstPersona) }
                        )
                    case .firstPersona:
                        WelcomeFirstPersonaStep(
                            hostId: host?.id,
                            harness: OnboardingLogic.setupHarness(verified: verifiedOrdered),
                            hasHarness: !verifiedOrdered.isEmpty || (context.store.entry(Self.bootRequest).data?.me.harnessConnected == true),
                            onBack: { advance(to: .appTour) },
                            onConnectHarness: { advance(to: .connectHarness) },
                            onDone: onDone
                        )
                    }
                }
                .id(step)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 10)),
                    removal: .opacity.combined(with: .offset(y: -8))
                ))
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.border))
                .padding(.top, 18)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(p.background)
        .onAppear {
            hour = Calendar.current.component(.hour, from: Date())
            context.store.load(Self.personasRequest)
            context.store.load(Self.modelsRequest)
            context.store.load(Self.secretsRequest)
            syncVerifiedFromModels()
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
        }
        .onChange(of: context.store.entry(Self.modelsRequest).data) { _, _ in
            syncVerifiedFromModels()
        }
    }

    private func resolveHost(from list: API.PersonaList?) -> API.Persona? {
        guard let list else { return nil }
        if let defaultId = list.defaultPersonaId,
           let match = list.personas.first(where: { $0.id == defaultId }) {
            return match
        }
        return list.personas.first(where: \.isDefault) ?? list.personas.first
    }

    private func syncVerifiedFromModels() {
        let groups = context.store.entry(Self.modelsRequest).data ?? []
        let existing = OnboardingLogic.alreadyVerifiedHarnesses(from: groups)
        for (harness, count) in existing where verifiedHarnesses[harness] == nil {
            verifiedHarnesses[harness] = count
        }
    }

    private func advance(to next: OnboardingLogic.WizardStep) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.22)) {
            step = next
        }
    }

    @ViewBuilder
    private func hostPortrait(host: API.Persona?, palette p: NativePalette) -> some View {
        let accent = Color(cssHex: host?.color) ?? p.accent
        ZStack {
            Circle()
                .fill(accent.opacity(theme.mode == .dark ? 0.16 : 0.12))
                .frame(width: 92, height: 92)
                .scaleEffect(!reduceMotion && breathe ? 1.07 : 0.96)
            WorkPersonaAvatarView(
                id: host?.id,
                handle: nil,
                name: host?.name ?? "Assistant",
                size: 72,
                state: .idle,
                active: true,
                preferCharacter: true
            )
            .shadow(color: accent.opacity(0.25), radius: 10, y: 3)
        }
        .frame(width: 96, height: 96)
    }

    private func stepProgressHeader(palette p: NativePalette) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(OnboardingLogic.setupSteps.enumerated()), id: \.offset) { idx, item in
                let state = OnboardingLogic.rowState(row: idx, step: step)
                Button {
                    if state == .done {
                        advance(to: item)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: state == .done ? "checkmark.circle.fill" : "\(idx + 1).circle\(state == .current ? ".fill" : "")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(
                                state == .done
                                    ? theme.swiftUIColor("state-done", fallback: .green)
                                    : (state == .current ? p.accent : p.tertiaryText)
                            )
                        Text(item.title)
                            .font(.system(size: theme.pointSize(.small), weight: state == .current ? .semibold : .regular))
                            .foregroundStyle(state == .current ? p.text : p.secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        state == .current ? p.selected : Color.clear,
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state != .done)
            }
        }
    }
}

// MARK: - Typewriter Assistant Line

private struct WizardSaidLine: View {
    @Environment(\.vesperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    @State private var shownCount = 0

    var body: some View {
        let displayed = reduceMotion ? text : String(text.prefix(shownCount))
        let done = reduceMotion || shownCount >= text.count

        HStack(spacing: 0) {
            Text(displayed + (done ? "" : "▎"))
                .font(.system(size: theme.pointSize(.body) + 1))
                .foregroundStyle(theme.palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 480, minHeight: 40, alignment: .top)
        .accessibilityLabel(text)
        .task(id: text) {
            if reduceMotion {
                shownCount = text.count
                return
            }
            shownCount = 0
            let total = text.count
            while shownCount < total && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                shownCount += 1
            }
        }
    }
}

// MARK: - Step 0: Greeting

private struct WelcomeGreetingStep: View {
    @Environment(\.vesperTheme) private var theme
    let onNext: () -> Void

    private struct PreviewItem: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
    }

    private let items: [PreviewItem] = [
        PreviewItem(id: "profile", icon: "users", title: "Create your profile", detail: "Tell personas your name, what you do, and an optional photo."),
        PreviewItem(id: "harness", icon: "agents", title: "Connect an AI harness", detail: "Wire up Claude Code, Codex, Antigravity, or any mix."),
        PreviewItem(id: "tour", icon: "dashboard", title: "Tour Vesper’s built-in apps", detail: "See Chat, Spaces, Knowledge, Library, Browser, and workbench tools."),
        PreviewItem(id: "persona", icon: "msg", title: "Craft your first persona", detail: "Describe who you want to talk to in plain English—I’ll draft them for you."),
    ]

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 14) {
            Text("Four quick steps to make Vesper yours:")
                .font(.system(size: theme.pointSize(.body), weight: .medium))
                .foregroundStyle(p.secondaryText)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: SidebarIcons.symbolName(item.icon))
                            .font(.system(size: 13))
                            .foregroundStyle(p.accent)
                            .frame(width: 26, height: 26)
                            .background(p.selected, in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: theme.pointSize(.body), weight: .semibold))
                                .foregroundStyle(p.text)
                            Text(item.detail)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.secondaryText)
                        }
                    }
                }
            }

            Divider()
                .padding(.top, 4)

            HStack {
                Text("Everything can be changed later in Settings.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.tertiaryText)
                Spacer()
                Button("Let’s begin", action: onNext)
                    .buttonStyle(.vesper(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Step 1: About You (Profile)

private struct WelcomeAboutYouStep: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let onBack: () -> Void
    let onNext: () -> Void

    @State private var name = ""
    @State private var role = ""
    @State private var email = ""
    @State private var hydrated = false
    @State private var stagedPhoto: (data: Data, fileName: String, mimeType: String, image: NSImage)?
    @State private var isDropping = false
    @State private var busy = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private static let bootRequest = API.getBootstrap()

    var body: some View {
        let p = theme.palette
        let me = context.store.entry(Self.bootRequest).data?.me
        let roleTooLong = !OnboardingLogic.isValidRole(role)
        let nameValid = OnboardingLogic.isValidName(name)

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                avatarDropTarget(me: me, palette: p)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your name")
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                                .foregroundStyle(p.secondaryText)
                            TextField("e.g. Ada Lovelace", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .focused($nameFocused)
                                .onSubmit { if nameValid && !roleTooLong && !busy { save(me: me) } }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("What you do")
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                                .foregroundStyle(p.secondaryText)
                            TextField("e.g. Backend engineer, Go", text: $role)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { if nameValid && !roleTooLong && !busy { save(me: me) } }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Primary email")
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                                .foregroundStyle(p.secondaryText)
                            TonePill(label: "Optional", tone: "neutral")
                        }
                        TextField("you@example.com — used for git commits in coding chats", text: $email)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { if nameValid && !roleTooLong && !busy { save(me: me) } }
                    }

                    HStack(spacing: 6) {
                        Text("Profile photo")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.tertiaryText)
                        TonePill(label: "Optional", tone: "neutral")
                        if stagedPhoto != nil {
                            Text("· looking good ·")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.tertiaryText)
                            Button("Remove") { stagedPhoto = nil }
                                .buttonStyle(.plain)
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                                .foregroundStyle(p.accent)
                        } else {
                            Text("· click the circle or drop an image")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.tertiaryText)
                        }
                    }
                }
            }

            if roleTooLong {
                wizardErrorBanner("Keep “What you do” to \(OnboardingLogic.roleMax) characters.", theme: theme)
            }
            if let errorMessage {
                wizardErrorBanner(errorMessage, theme: theme)
            }

            Divider()

            HStack(spacing: 8) {
                Text("You can change these anytime in Settings.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.tertiaryText)
                Spacer()
                Button("Back", action: onBack)
                    .buttonStyle(.vesper())
                    .disabled(busy)
                Button(busy ? "Saving…" : "Continue") {
                    save(me: me)
                }
                .buttonStyle(.vesper(.primary))
                .disabled(!nameValid || roleTooLong || busy)
            }
        }
        .onAppear {
            hydrate(from: me)
            nameFocused = true
        }
        .onChange(of: me?.id) { _, _ in
            hydrate(from: me)
        }
    }

    private func avatarDropTarget(me: API.User?, palette p: NativePalette) -> some View {
        Button {
            pickPhoto()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(hex: 0x3A2D7C),
                            Color(hex: 0x6F56C7),
                            Color(hex: 0xE6B97A),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(OnboardingLogic.initialOf(name))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFFF6DD))

                    if let staged = stagedPhoto {
                        Image(nsImage: staged.image)
                            .resizable()
                            .scaledToFill()
                    } else if let avatarUrl = me?.avatarUrl, !avatarUrl.isEmpty {
                        AuthenticatedImageView(source: avatarUrl, maxPixel: 200) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        } failure: {
                            Color.clear
                        }
                    }
                }
                .frame(width: 68, height: 68)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(isDropping ? p.accent : p.border, lineWidth: isDropping ? 2.5 : 1.5)
                )

                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.swiftUIColor("text-on-accent", fallback: .white))
                    .frame(width: 22, height: 22)
                    .background(p.accent, in: Circle())
                    .overlay(Circle().stroke(p.surface, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Upload a profile photo (PNG, JPG or WebP, up to 1 MB)")
        .onDrop(of: [.fileURL], isTargeted: $isDropping) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    stagePhoto(from: url)
                }
            }
            return true
        }
    }

    private func hydrate(from me: API.User?) {
        guard !hydrated, let me else { return }
        hydrated = true
        name = OnboardingLogic.prefillName(me.name)
        role = me.roleTitle
        email = OnboardingLogic.prefillEmail(me.email)
    }

    private func pickPhoto() {
        guard let picked = SettingsFilePanels.openImageForAvatar() else { return }
        stagePhoto(data: picked.data, fileName: picked.fileName, mimeType: picked.mimeType)
    }

    private func stagePhoto(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn’t read that image file."
            return
        }
        let ext = url.pathExtension.lowercased()
        let mime: String = switch ext {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        default: "application/octet-stream"
        }
        stagePhoto(data: data, fileName: url.lastPathComponent, mimeType: mime)
    }

    private func stagePhoto(data: Data, fileName: String, mimeType: String) {
        if let err = PersonaUIHelpers.validateAvatarData(data, fileName: fileName, contentType: mimeType) {
            errorMessage = err
            return
        }
        guard let image = NSImage(data: data) else {
            errorMessage = "Use a valid PNG, JPG or WebP image."
            return
        }
        errorMessage = nil
        stagedPhoto = (data, fileName, mimeType, image)
    }

    private func save(me: API.User?) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        let patch = OnboardingLogic.profilePatch(
            name: name,
            role: role,
            email: email,
            existingEmails: me?.emails
        )
        let saveWork = OnboardingLogic.shouldSaveWorkMemory(role: role, previousRole: me?.roleTitle)
        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let photoToUpload = stagedPhoto

        Task {
            defer { busy = false }
            do {
                let updated = try await context.store.mutate(
                    API.updateProfile(body: patch),
                    invalidating: QueryInvalidation(resources: ["me", "bootstrap"])
                )
                context.store.setData(updated, for: API.getProfile())
                if let photo = photoToUpload, let client = context.store.client {
                    var form = APIMultipartForm()
                    form.addFile(
                        "file",
                        filename: photo.fileName,
                        contentType: photo.mimeType.isEmpty ? "application/octet-stream" : photo.mimeType,
                        data: photo.data
                    )
                    let withPhoto = try await client.send(API.uploadProfileAvatar(body: form))
                    context.store.setData(withPhoto, for: API.getProfile())
                    context.store.invalidate(QueryInvalidation(resources: ["me", "bootstrap"]))
                }
                if saveWork {
                    _ = try await context.store.mutate(
                        API.createMemory(body: API.MemoryCreate(
                            body: trimmedRole,
                            summary: trimmedRole,
                            title: "What I do",
                            type: "work"
                        )),
                        invalidating: QueryInvalidation(resources: ["memories"])
                    )
                }
                _ = await context.store.refetch(Self.bootRequest)
                onNext()
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Step 2: Connect a Harness

private struct WelcomeConnectHarnessStep: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let harnessOnly: Bool
    @Binding var verified: [API.Harness: Int]
    let onBack: (() -> Void)?
    let onSkip: (() -> Void)?
    let onNext: () -> Void

    private static let secretsRequest = API.listSecrets()
    private static let modelsRequest = API.listChatModels()

    var body: some View {
        let p = theme.palette
        let secretsData = context.store.entry(Self.secretsRequest).data
        let secretsOff = secretsData.map { !$0.keyConfigured } ?? false
        let hostLogins = secretsData?.harnessKeysRequired == false
        let signInAvailable = secretsData?.signInAvailable ?? false
        let secretInfos = secretsData?.secrets ?? []
        let done = OnboardingLogic.harnessCards.map(\.harness).filter { verified[$0] != nil }

        VStack(alignment: .leading, spacing: 14) {
            if hostLogins {
                infoCallout(
                    "This server runs Claude Code, Codex and Antigravity with the `claude`, `codex` and `agy` sign-ins on its host. Sign the CLI in there, then click Verify.",
                    palette: p
                )
            } else if secretsOff {
                infoCallout(
                    "Secrets are off on this server (SECRETS_KEY isn’t set), so Vesper can’t store a credential here yet. Set SECRETS_KEY and restart, then connect a harness.",
                    palette: p
                )
            }

            VStack(spacing: 10) {
                ForEach(OnboardingLogic.harnessCards) { spec in
                    let stored = secretInfos.contains { $0.name == spec.secretName && $0.project == nil }
                    WizardHarnessCard(
                        spec: spec,
                        pasteEnabled: !hostLogins && !secretsOff,
                        hostLogins: hostLogins,
                        signInAvailable: signInAvailable && !hostLogins && !secretsOff,
                        stored: stored,
                        verifiedCount: verified[spec.harness]
                    ) { count in
                        verified[spec.harness] = count
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text(OnboardingLogic.harnessHint(verified: done))
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(2)
                Spacer()
                if let onBack {
                    Button("Back", action: onBack)
                        .buttonStyle(.vesper())
                }
                if let onSkip, done.isEmpty {
                    Button("Skip for now", action: onSkip)
                        .buttonStyle(.vesper())
                }
                Button(harnessOnly ? "Done" : "Continue", action: onNext)
                    .buttonStyle(.vesper(.primary))
                    .disabled(done.isEmpty)
            }
        }
        .onAppear {
            context.store.load(Self.secretsRequest)
            context.store.load(Self.modelsRequest)
        }
    }

    private func infoCallout(_ text: String, palette p: NativePalette) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(p.accent)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(p.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
    }
}

private struct WizardHarnessCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let spec: OnboardingLogic.HarnessCardSpec
    let pasteEnabled: Bool
    let hostLogins: Bool
    let signInAvailable: Bool
    let stored: Bool
    let verifiedCount: Int?
    let onVerified: @MainActor (Int) -> Void

    @State private var pickedKind: API.HarnessVerifyRequest.Kind = .subscription
    @State private var credential = ""
    @State private var showManualPaste = false
    @State private var checking = false
    @State private var verifying = false
    @State private var errorMessage: String?
    @State private var verifyTask: Task<Void, Never>?

    // Interactive native sign-in state (when microVM runner supports POST /sign-ins)
    @State private var activeSignIn: API.SignIn?
    @State private var signInCode = ""
    @State private var signInPollTask: Task<Void, Never>?

    private var effectiveKind: API.HarnessVerifyRequest.Kind {
        spec.subscriptionOnly ? .subscription : pickedKind
    }

    private var isVerified: Bool { verifiedCount != nil }
    private var busy: Bool { verifying || checking }

    var body: some View {
        let p = theme.palette
        let doneColor = theme.swiftUIColor("state-done", fallback: .green)
        let manualVisible = pasteEnabled && (!signInAvailable || showManualPaste)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                if let charKind = HarnessCharacterView.kind(for: spec.harness.rawValue) {
                    HarnessCharacterView(kind: charKind, working: busy || activeSignIn != nil, size: 28)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(spec.label)
                            .font(.system(size: theme.pointSize(.body), weight: .semibold))
                            .foregroundStyle(p.text)
                        if spec.images {
                            TonePill(label: "Images", tone: "review")
                        }
                        if stored && !isVerified {
                            TonePill(label: "Saved", tone: "neutral")
                        }
                    }
                    Text(spec.by)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.tertiaryText)
                }

                Spacer(minLength: 8)

                if let count = verifiedCount {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                        Text("\(count) \(count == 1 ? "model" : "models")")
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    }
                    .foregroundStyle(doneColor)
                } else if signInAvailable && activeSignIn == nil {
                    Button("Sign in") {
                        startSignIn()
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(busy)
                }

                if hostLogins || (stored && !isVerified && !manualVisible) || (!pasteEnabled && !signInAvailable) {
                    Button(busy ? "Checking…" : (isVerified ? "Verified" : "Verify")) {
                        runVerify()
                    }
                    .buttonStyle(.vesper())
                    .disabled(busy)
                }
            }

            if let signIn = activeSignIn {
                signInInlinePanel(signIn, palette: p)
            }

            if signInAvailable && !isVerified && activeSignIn == nil {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showManualPaste.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showManualPaste ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(spec.subscriptionOnly ? "Or paste a saved login bundle" : "Or paste a key or login token")
                            .font(.system(size: theme.pointSize(.small)))
                    }
                    .foregroundStyle(p.secondaryText)
                }
                .buttonStyle(.plain)
            }

            if manualVisible {
                VStack(alignment: .leading, spacing: 8) {
                    if !spec.subscriptionOnly {
                        Picker("\(spec.label) sign-in", selection: $pickedKind) {
                            Text("Subscription").tag(API.HarnessVerifyRequest.Kind.subscription)
                            Text("API key").tag(API.HarnessVerifyRequest.Kind.apiKey)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 240)
                    }

                    HStack(spacing: 8) {
                        SecureField(
                            OnboardingLogic.credentialPlaceholder(harness: spec.harness, kind: effectiveKind),
                            text: $credential
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy {
                                runVerify()
                            }
                        }

                        Button(busy ? "Verifying…" : (isVerified ? "Re-verify" : "Verify")) {
                            runVerify()
                        }
                        .buttonStyle(.vesper())
                        .disabled(busy || (credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !stored))
                    }

                    Text(OnboardingLogic.credentialHelp(harness: spec.harness, kind: effectiveKind))
                        .font(.system(size: theme.pointSize(.micro) + 1))
                        .foregroundStyle(p.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Asking the runner for available models…")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                }
            }

            if let errorMessage {
                wizardErrorBanner(errorMessage, theme: theme)
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isVerified ? doneColor.opacity(0.6) : p.border, lineWidth: isVerified ? 1.25 : 1)
        )
        .onDisappear {
            verifyTask?.cancel()
            signInPollTask?.cancel()
        }
    }

    @ViewBuilder
    private func signInInlinePanel(_ signIn: API.SignIn, palette p: NativePalette) -> some View {
        let viewState = ProviderSecretsHelpers.signInView(signIn)
        VStack(alignment: .leading, spacing: 8) {
            if let instructions = ProviderSecretsHelpers.signInSteps[signIn.provider] {
                Text(instructions)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
            }
            switch viewState {
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting sign-in session…")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                }
            case .open(let urlStr, let code, let pasteBack):
                HStack(spacing: 8) {
                    Button("Open Sign-In Page") {
                        context.openExternal(urlStr)
                    }
                    .buttonStyle(.vesper(.primary))
                    if !code.isEmpty {
                        Text(code)
                            .font(.system(size: theme.pointSize(.body), weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy Code") {
                            context.copyToClipboard(code)
                        }
                        .buttonStyle(.vesper())
                    }
                }
                if pasteBack {
                    HStack(spacing: 8) {
                        TextField("Paste authorization code or callback URL", text: $signInCode)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { submitSignInCode(id: signIn.id) }
                        Button("Submit") {
                            submitSignInCode(id: signIn.id)
                        }
                        .buttonStyle(.vesper(.primary))
                        .disabled(signInCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verifying authorization…")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                }
            case .done:
                Text("Signed in! Checking models…")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
            case .failed(let msg):
                wizardErrorBanner(msg, theme: theme)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    cancelSignIn(id: signIn.id)
                }
                .buttonStyle(.vesper())
            }
        }
        .padding(10)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
    }

    private func runVerify(skipCredential: Bool = false) {
        verifyTask?.cancel()
        errorMessage = nil
        verifying = true
        let raw = skipCredential ? "" : credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { credential = "" }
        let body: API.HarnessVerifyRequest? = (!raw.isEmpty && pasteEnabled)
            ? API.HarnessVerifyRequest(credential: raw, kind: effectiveKind)
            : nil

        verifyTask = Task {
            defer {
                verifying = false
                checking = false
            }
            do {
                var result = try await context.store.mutate(
                    API.verifyHarness(harness: spec.harness, body: body),
                    invalidating: QueryInvalidation(resources: ["secrets", "chat-models", "bootstrap"])
                )
                if result.ok {
                    onVerified(result.models.count)
                    return
                }
                // A plan login's models come back from the runner asynchronously: poll briefly.
                var retries = 0
                while result.checking == true && retries < 15 && !Task.isCancelled {
                    checking = true
                    retries += 1
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    result = try await context.store.mutate(
                        API.verifyHarness(harness: spec.harness, body: nil),
                        invalidating: QueryInvalidation(resources: ["chat-models"])
                    )
                    if result.ok {
                        onVerified(result.models.count)
                        return
                    }
                }
                errorMessage = result.error ?? "No chat models came back."
            } catch {
                if !Task.isCancelled {
                    errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
                }
            }
        }
    }

    private func startSignIn() {
        guard let client = context.store.client else { return }
        signInPollTask?.cancel()
        signInCode = ""
        errorMessage = nil
        Task {
            do {
                let s = try await client.send(API.startSignIn(body: API.StartSignInBody(provider: spec.signInProvider)))
                activeSignIn = s
                pollSignIn(id: s.id)
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func pollSignIn(id: String) {
        signInPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let client = context.store.client else { return }
                if let next = try? await client.send(API.getSignIn(id: id)) {
                    activeSignIn = next
                    if next.status == .done {
                        activeSignIn = nil
                        _ = await context.store.refetch(API.listSecrets())
                        runVerify(skipCredential: true)
                        return
                    }
                    if next.status == .failed || next.status == .cancelled {
                        return
                    }
                }
            }
        }
    }

    private func submitSignInCode(id: String) {
        guard let client = context.store.client else { return }
        let code = signInCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        Task {
            do {
                activeSignIn = try await client.send(
                    API.submitSignInCode(id: id, body: API.SubmitSignInCodeBody(code: code))
                )
                signInCode = ""
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func cancelSignIn(id: String) {
        signInPollTask?.cancel()
        activeSignIn = nil
        Task {
            _ = try? await context.store.client?.send(API.cancelSignIn(id: id))
        }
    }
}

// MARK: - Step 3: Default Apps Tour

private struct WelcomeAppTourStep: View {
    @Environment(\.vesperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onBack: () -> Void
    let onNext: () -> Void

    @State private var activeIndex = 0
    @State private var visited: Set<Int> = [0]

    private var items: [OnboardingLogic.AppTourItem] { OnboardingLogic.defaultAppTour }

    var body: some View {
        let p = theme.palette
        let current = items[min(activeIndex, items.count - 1)]

        VStack(alignment: .leading, spacing: 14) {
            // App selector strip mirroring Vesper's sidebar area bar
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    let selected = idx == activeIndex
                    let seen = visited.contains(idx)
                    Button {
                        select(idx)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: SidebarIcons.symbolName(item.icon))
                                .font(.system(size: 12))
                                .foregroundStyle(selected ? p.accent : p.secondaryText)
                            Text(item.name)
                                .font(.system(size: theme.pointSize(.small), weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? p.text : p.secondaryText)
                                .lineLimit(1)
                            if seen && !selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            selected ? p.selected : theme.swiftUIColor("surface-sunken", fallback: p.background),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selected ? p.accent.opacity(0.7) : p.border)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Spotlight card for the selected default app
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: SidebarIcons.symbolName(current.icon))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(p.accent)
                        .frame(width: 44, height: 44)
                        .background(p.selected, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.accent.opacity(0.3)))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(current.name)
                                .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                                .foregroundStyle(p.text)
                            TonePill(label: current.badge, tone: "neutral")
                            Spacer()
                            Text("\(activeIndex + 1) of \(items.count)")
                                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                        }
                        Text(current.tagline)
                            .font(.system(size: theme.pointSize(.body), weight: .medium))
                            .foregroundStyle(p.secondaryText)
                    }
                }

                Text(current.summary)
                    .font(.system(size: theme.pointSize(.body)))
                    .foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(current.highlights, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 10))
                                .foregroundStyle(p.accent)
                                .padding(.top, 3)
                            Text(bullet)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !current.subTools.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(current.subTools, id: \.self) { tool in
                            Text(tool)
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                                .foregroundStyle(p.text)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(p.surface, in: Capsule())
                                .overlay(Capsule().stroke(p.border))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .id(current.id)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))

            Divider()

            HStack(spacing: 8) {
                Button("Back", action: onBack)
                    .buttonStyle(.vesper())

                Spacer()

                if let prev = OnboardingLogic.previousTourIndex(from: activeIndex) {
                    Button("Previous") { select(prev) }
                        .buttonStyle(.vesper())
                }

                if let next = OnboardingLogic.nextTourIndex(from: activeIndex, count: items.count) {
                    Button("Skip tour", action: onNext)
                        .buttonStyle(.vesper())
                    Button("Next: \(items[next].name)") { select(next) }
                        .buttonStyle(.vesper(.primary))
                } else {
                    Button("Continue", action: onNext)
                        .buttonStyle(.vesper(.primary))
                }
            }
        }
    }

    private func select(_ index: Int) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            activeIndex = index
            visited.insert(index)
        }
    }
}

// MARK: - Step 4: Your First Persona (Natural Language with Default Assistant)

private struct WelcomeFirstPersonaStep: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let hostId: String?
    let harness: API.Harness?
    let hasHarness: Bool
    let onBack: () -> Void
    let onConnectHarness: () -> Void
    let onDone: @MainActor (String?) -> Void

    @State private var descriptionText = ""
    @State private var setupChatId: String?
    @State private var beforeIds: Set<String> = []
    @State private var sentAt: Date?
    @State private var proposals: [API.PersonaProposal] = []
    @State private var proposalsUpdatedAt: Date?
    @State private var chatRunning: Bool?
    @State private var chatUpdatedAt: Date?
    @State private var sending = false
    @State private var meeting = false
    @State private var skipping = false
    @State private var approvedPersonaId: String?
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?

    private static let bootRequest = API.getBootstrap()
    private static let personasRequest = API.listPersonas()

    private var evaluation: OnboardingLogic.DraftEvaluation {
        OnboardingLogic.evaluateDraft(
            proposals: proposals,
            beforeIds: beforeIds,
            sentAt: sentAt,
            chatRunning: chatRunning,
            chatUpdatedAt: chatUpdatedAt,
            proposalsUpdatedAt: proposalsUpdatedAt
        )
    }

    var body: some View {
        let p = theme.palette
        let eval = evaluation
        let busy = sending || eval.waiting || meeting || skipping
        let shownError: String? = {
            if let errorMessage { return errorMessage }
            if eval.failed {
                return "No draft came back. Try describing them differently, or check that your Assistant may create personas in Settings → Personas."
            }
            return nil
        }()

        VStack(alignment: .leading, spacing: 12) {
            if !hasHarness {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(theme.swiftUIColor("state-human", fallback: .orange))
                    Text("Connect a harness first so your Assistant can draft a custom persona for you—or skip for now and start chatting later.")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                    Spacer()
                    Button("Connect harness", action: onConnectHarness)
                        .buttonStyle(.vesper())
                }
                .padding(10)
                .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(eval.draft != nil ? "Refine in your own words" : "Describe who you’d like to talk to")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.secondaryText)

                ZStack(alignment: .topLeading) {
                    if descriptionText.isEmpty {
                        Text(eval.draft != nil ? "Tell me what to change (e.g. “Make them more playful”)…" : "A blunt senior engineer who pairs with me…")
                            .font(.system(size: theme.pointSize(.body)))
                            .foregroundStyle(p.tertiaryText)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $descriptionText)
                        .font(.system(size: theme.pointSize(.body)))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 62, maxHeight: 110)
                        .padding(4)
                        .disabled(busy || !hasHarness || approvedPersonaId != nil)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored }
                            guard !busy, hasHarness, approvedPersonaId == nil,
                                  !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                return .handled
                            }
                            sendDraftRequest()
                            return .handled
                        }
                }
                .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
            }

            if eval.draft == nil && !eval.waiting && hasHarness {
                FlowLayout(spacing: 6) {
                    ForEach(OnboardingLogic.personaExamples, id: \.self) { example in
                        Button {
                            descriptionText = example
                        } label: {
                            Text(example)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.secondaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(p.surface, in: Capsule())
                                .overlay(Capsule().stroke(p.border))
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
            }

            if eval.waiting || eval.draft != nil {
                WizardPersonaDraftCard(draft: (eval.waiting && eval.fresh == nil) ? nil : eval.draft)
            }

            if let shownError {
                wizardErrorBanner(shownError, theme: theme)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Back", action: onBack)
                    .buttonStyle(.vesper())
                    .disabled(busy)

                if eval.draft != nil && !eval.waiting {
                    Text("Tell me what to change, or meet them.")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }

                Spacer()

                Button(skipping ? "Finishing…" : "Skip for now") {
                    skipAndFinish()
                }
                .buttonStyle(.vesper())
                .disabled(busy)

                if hasHarness {
                    Button {
                        sendDraftRequest()
                    } label: {
                        HStack(spacing: 6) {
                            if sending || eval.waiting {
                                ProgressView().controlSize(.small)
                            }
                            Text(sending || eval.waiting ? "Drafting…" : (eval.draft != nil ? "Redraft" : "Draft persona"))
                        }
                    }
                    .buttonStyle(.vesper())
                    .disabled(busy || descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || approvedPersonaId != nil)

                    Button(meeting ? "Meeting…" : "Meet them") {
                        meetDraftedPersona()
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(!(eval.ready || approvedPersonaId != nil) || busy)
                }
            }
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    private func sendDraftRequest() {
        let words = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !sending else { return }
        guard let client = context.store.client else {
            errorMessage = "Not connected to the Vesper server."
            return
        }
        sending = true
        errorMessage = nil
        let existingDraft = evaluation.draft
        let existingIds = Set(proposals.map(\.id))

        Task {
            defer { sending = false }
            do {
                let chatId: String
                if let current = setupChatId {
                    chatId = current
                    if let old = existingDraft {
                        _ = try await client.send(
                            API.decidePersonaProposal(
                                id: chatId,
                                proposalId: old.id,
                                body: API.DecidePersonaProposalBody(decision: .decline)
                            )
                        )
                    }
                } else {
                    let created = try await client.send(
                        API.createChat(body: API.NewChat(
                            hidden: true,
                            personaId: hostId,
                            temporary: true,
                            title: "Welcome setup"
                        ))
                    )
                    chatId = created.id
                    setupChatId = chatId
                }

                let prompt = existingDraft != nil
                    ? OnboardingLogic.refinePrompt(words)
                    : OnboardingLogic.draftPrompt(words)

                _ = try await client.send(
                    API.postChatMessage(
                        id: chatId,
                        body: API.NewChatMessage(body: prompt, harness: harness)
                    )
                )

                beforeIds = existingIds
                sentAt = Date()
                chatRunning = true
                chatUpdatedAt = Date()
                descriptionText = ""
                startPolling(chatId: chatId)
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func startPolling(chatId: String) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                guard let client = context.store.client else { return }
                if let session = try? await client.send(API.getChat(id: chatId)) {
                    chatRunning = (session.state == .running)
                    chatUpdatedAt = Date()
                }
                if let list = try? await client.send(API.listPersonaProposals(id: chatId)) {
                    proposals = list.proposals
                    proposalsUpdatedAt = Date()
                }
                if !evaluation.waiting {
                    return
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private func meetDraftedPersona() {
        guard let chatId = setupChatId, let client = context.store.client else { return }
        guard evaluation.draft != nil || approvedPersonaId != nil else { return }
        meeting = true
        errorMessage = nil
        pollTask?.cancel()

        Task {
            do {
                let personaId: String
                if let existing = approvedPersonaId {
                    personaId = existing
                } else if let draft = evaluation.draft {
                    let decided = try await client.send(
                        API.decidePersonaProposal(
                            id: chatId,
                            proposalId: draft.id,
                            body: API.DecidePersonaProposalBody(decision: .approve)
                        )
                    )
                    guard let createdId = decided.persona?.id else {
                        errorMessage = "The persona wasn’t created. Please try again."
                        meeting = false
                        return
                    }
                    personaId = createdId
                    approvedPersonaId = createdId
                } else {
                    meeting = false
                    return
                }

                _ = try await context.store.mutate(
                    API.setDefaultPersona(id: personaId),
                    invalidating: QueryInvalidation(resources: ["personas", "chats"])
                )
                let completedUser = try await context.store.mutate(
                    API.completeOnboarding(),
                    invalidating: QueryInvalidation(resources: ["me", "bootstrap"])
                )
                context.store.setData(completedUser, for: API.getProfile())
                _ = await context.store.refetch(Self.personasRequest)
                _ = await context.store.refetch(Self.bootRequest)
                onDone(personaId)
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
                meeting = false
            }
        }
    }

    private func skipAndFinish() {
        guard !skipping else { return }
        skipping = true
        errorMessage = nil
        pollTask?.cancel()
        Task {
            defer { skipping = false }
            do {
                let completedUser = try await context.store.mutate(
                    API.completeOnboarding(),
                    invalidating: QueryInvalidation(resources: ["me", "bootstrap"])
                )
                context.store.setData(completedUser, for: API.getProfile())
                _ = await context.store.refetch(Self.bootRequest)
                onDone(nil)
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

private struct WizardPersonaDraftCard: View {
    @Environment(\.vesperTheme) private var theme
    let draft: API.PersonaProposal?

    var body: some View {
        let p = theme.palette
        if let draft {
            let bullets = OnboardingLogic.draftBullets(draft.customInstructions)
            let avatarPath: String? = (draft.avatarState == .ready && draft.avatarAttachmentId != nil)
                ? "/api/v1/chat-attachments/\(APIPath.escape(draft.avatarAttachmentId!))/content"
                : nil

            HStack(alignment: .top, spacing: 12) {
                draftAvatar(draft: draft, avatarPath: avatarPath)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(draft.name)
                            .font(.system(size: theme.pointSize(.body) + 1, weight: .semibold))
                            .foregroundStyle(p.text)
                        TonePill(label: PersonaUIHelpers.toneLabel(draft.tone), tone: "neutral")
                        if draft.avatarState == .pending {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("Generating portrait…")
                                    .font(.system(size: theme.pointSize(.micro)))
                                    .foregroundStyle(p.tertiaryText)
                            }
                        }
                    }

                    if !draft.reason.isEmpty {
                        Text(draft.reason)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                    }

                    if !bullets.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(bullets, id: \.self) { bullet in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                        .foregroundStyle(p.tertiaryText)
                                    Text(bullet)
                                        .font(.system(size: theme.pointSize(.small)))
                                        .foregroundStyle(p.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
        } else {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(theme.swiftUIColor("track", fallback: Color.secondary.opacity(0.14)))
                    .frame(width: 44, height: 44)
                    .overlay(ProgressView().controlSize(.small))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Drafting your persona…")
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(p.secondaryText)
                    SkeletonBar(height: 10)
                        .frame(maxWidth: 220)
                }
                Spacer()
            }
            .padding(12)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
        }
    }

    @ViewBuilder
    private func draftAvatar(draft: API.PersonaProposal, avatarPath: String?) -> some View {
        let color = Color(cssHex: draft.color) ?? theme.palette.accent
        if let svg = draft.characterSvg, !svg.isEmpty {
            PersonaCharacterView(svg: svg, color: draft.color, state: .idle, size: 46, active: true, framed: true)
        } else if let avatarPath {
            AuthenticatedImageView(source: avatarPath, maxPixel: 200) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Circle().fill(color)
                    Text(OnboardingLogic.initialOf(draft.name))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } failure: {
                ZStack {
                    Circle().fill(color)
                    Text(OnboardingLogic.initialOf(draft.name))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(color)
                Text(OnboardingLogic.initialOf(draft.name))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
        }
    }
}

private func wizardErrorBanner(_ message: String, theme: ThemeTokens) -> some View {
    HStack(alignment: .top, spacing: 6) {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 12))
            .padding(.top, 1)
        Text(message)
            .font(.system(size: theme.pointSize(.small)))
            .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
}
