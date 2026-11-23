import SwiftUI
import VesperCore

/// Native `/apps` Custom Apps hub: lists sandboxed Custom Apps, starter templates, and creation sheet.
/// Opening an individual custom app (`/apps/<slug>`) routes to WKWebView as intended.
struct AppsHomeScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var showNewSheet = false
    @State private var initialTemplate: API.NewCustomApp.Template = .blank
    @State private var deleteTarget: API.CustomAppSummary?
    @State private var deletingSlug: String?
    @State private var navSearch = ""
    @State private var watchedKeys: [QueryKey] = []

    private static let listRequest = API.listCustomApps()
    private static let devWorkspaceRequest = API.getDevWorkspace()

    var body: some View {
        let p = theme.palette
        let entry = context.store.entry(Self.listRequest)
        let apps = entry.data?.apps ?? []
        let devEnabled = context.store.entry(Self.devWorkspaceRequest).data?.enabled ?? false
        let currentChrome = NativeChrome(
            title: "Custom Apps",
            toolbarItems: [
                ShellToolbarItem(id: "apps.new", label: "New app", icon: "plus", kind: .button, accent: true, showsLabel: true),
            ],
            navigator: AppsHomeLogic.navModel(
                apps: apps,
                search: navSearch,
                devWorkspaceEnabled: devEnabled,
                loading: entry.isFetching && entry.data == nil
            )
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom Apps")
                        .vesperText(.display, theme)
                    Text("Sandboxed React + SQLite apps inside your workbench, wired to Vesper APIs, MCP connectors, and your personas.")
                        .vesperText(.body, theme)
                        .foregroundStyle(p.secondaryText)
                }

                if let error = entry.error {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Couldn\u{2019}t load custom apps")
                                .font(.system(size: 13, weight: .semibold))
                            Text(error.userMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(p.secondaryText)
                        }
                        Spacer()
                        Button("Retry") {
                            Task { _ = await context.store.refetch(Self.listRequest) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(14)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                } else if entry.isFetching && entry.data == nil {
                    ProgressView("Loading custom apps\u{2026}")
                        .padding(.vertical, 24)
                } else if !apps.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 14)], spacing: 14) {
                        ForEach(apps, id: \.id) { app in
                            customAppCard(app, p: p)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 26))
                            .foregroundStyle(p.tertiaryText)
                        Text("Build your first custom app")
                            .vesperText(.heading, theme)
                        Text("Start from a template or ask a persona in Chat to scaffold an app with its own SQLite tables and views.")
                            .vesperText(.body, theme)
                            .foregroundStyle(p.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        Button {
                            openNew(template: .blank)
                        } label: {
                            Label("Create custom app", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(32)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("STARTER TEMPLATES")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(p.tertiaryText)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 380), spacing: 12)], spacing: 12) {
                        ForEach(AppsHomeLogic.starters) { starter in
                            Button {
                                openNew(template: starter.template)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Image(systemName: SidebarIcons.symbolName(starter.icon))
                                            .font(.system(size: 14))
                                            .foregroundStyle(p.text)
                                            .frame(width: 28, height: 28)
                                            .background(theme.swiftUIColor("surface-raised", fallback: p.surface), in: RoundedRectangle(cornerRadius: 6))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                                        Text(starter.label)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(p.text)
                                    }
                                    Text(starter.detail)
                                        .font(.system(size: 13))
                                        .foregroundStyle(p.secondaryText)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 4)
                                    Text("Start with \(starter.label) \u{2192}")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(p.accent)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
                                .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: currentChrome, initial: true) { _, next in
            context.chrome = next
        }
        .onAppear {
            context.chrome = currentChrome
            context.onCommand = { cmd in
                handleCommand(cmd)
            }
            context.store.observe(Self.listRequest)
            context.store.load(Self.listRequest)
            context.store.observe(Self.devWorkspaceRequest)
            context.store.load(Self.devWorkspaceRequest)
            watchedKeys = [Self.listRequest.key, Self.devWorkspaceRequest.key]
        }
        .onDisappear {
            context.onCommand = nil
            for key in watchedKeys { context.store.stopObserving(key) }
            watchedKeys = []
        }
        .sheet(isPresented: $showNewSheet) {
            NewCustomAppSheet(initialTemplate: initialTemplate) { created in
                showNewSheet = false
                context.navigate("/apps/\(created.slug)")
            }
            .environment(context)
            .environment(\.vesperTheme, theme)
        }
        .alert(
            "Delete \(deleteTarget?.name ?? "app")?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    deleteApp(target)
                }
            }
        } message: {
            Text("This permanently deletes the app, its version history, and its embedded SQLite database.")
        }
    }

    private func openNew(template: API.NewCustomApp.Template) {
        initialTemplate = template
        showNewSheet = true
    }

    private func handleCommand(_ cmd: NativeCommand) {
        if case .toolbarAction(itemId: "apps.new", _) = cmd {
            openNew(template: .blank)
            return
        }
        guard let action = AppsHomeLogic.navAction(for: cmd) else { return }
        switch action {
        case .newApp(let template):
            openNew(template: template)
        case .openPath(let path, let newTab):
            if newTab { context.openInNewTab(path) } else { context.navigate(path) }
        case .deleteApp(let slug):
            if let target = context.store.entry(Self.listRequest).data?.apps.first(where: { $0.slug == slug }) {
                deleteTarget = target
            }
        case .search(let value):
            navSearch = value
        }
    }

    private func customAppCard(_ app: API.CustomAppSummary, p: NativePalette) -> some View {
        let href = "/apps/\(app.slug)"
        let activeCaps = app.capabilities
            .filter { $0.value != .denied }
            .sorted { $0.key < $1.key }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: SidebarIcons.symbolName(AppsHomeLogic.resolveIcon(app.icon)))
                    .font(.system(size: 16))
                    .foregroundStyle(p.text)
                    .frame(width: 36, height: 36)
                    .background(theme.swiftUIColor("surface-raised", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))

                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        context.navigate(href)
                    } label: {
                        Text(app.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)

                    Text(href)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    deleteTarget = app
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(p.tertiaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(deletingSlug == app.slug)
                .help("Delete \(app.name)")
            }

            Text(app.description.isEmpty ? "Custom workbench app" : app.description)
                .font(.system(size: 13))
                .foregroundStyle(p.secondaryText)
                .lineLimit(2)
                .frame(minHeight: 34, alignment: .topLeading)

            if !activeCaps.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(activeCaps.prefix(3)), id: \.key) { cap, mode in
                        Text("\(cap)\(mode == .requiresApproval ? " (ask)" : "")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(p.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
                            .lineLimit(1)
                    }
                    if activeCaps.count > 3 {
                        Text("+\(activeCaps.count - 3)")
                            .font(.system(size: 10))
                            .foregroundStyle(p.tertiaryText)
                    }
                }
            }

            Divider()

            HStack {
                Text("v\(app.currentSeq) \u{00B7} SQLite \u{00B7} \(AppsHomeLogic.formatBytes(app.dbSizeBytes)) \u{00B7} \(APIDate.shortAgo(app.updatedAt))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
                Spacer()
                Button("Open \u{2192}") {
                    context.navigate(href)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(p.accent)
            }
        }
        .padding(14)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
        .contextMenu {
            Button("Open \(app.name)") { context.navigate(href) }
            Button("Open in new tab") { context.openInNewTab(href) }
            Divider()
            Button("Copy link") {
                let full = context.resolvedURL(href)?.absoluteString ?? href
                context.copyToClipboard(full)
                context.showToast(ToastItemModel(id: "apps.copy", title: "Link copied", tone: .success))
            }
            Divider()
            Button("Delete \(app.name)", role: .destructive) { deleteTarget = app }
        }
    }

    private func deleteApp(_ app: API.CustomAppSummary) {
        deletingSlug = app.slug
        deleteTarget = nil
        Task {
            defer { deletingSlug = nil }
            do {
                _ = try await context.store.mutate(
                    API.deleteCustomApp(slug: app.slug),
                    invalidating: QueryInvalidation(resources: ["custom_apps"])
                )
                _ = await context.store.refetch(Self.listRequest)
                context.showToast(ToastItemModel(id: "apps.del.\(app.slug)", title: "Deleted \(app.name)", tone: .success))
            } catch {
                let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
                context.showToast(ToastItemModel(id: "apps.del.\(app.slug)", title: "Couldn\u{2019}t delete \(app.name)", description: msg, tone: .error))
            }
        }
    }
}

private struct NewCustomAppSheet: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let initialTemplate: API.NewCustomApp.Template
    let onCreated: (API.CustomAppDetail) -> Void

    @State private var template: API.NewCustomApp.Template
    @State private var name = ""
    @State private var slug = ""
    @State private var slugTouched = false
    @State private var description = ""
    @State private var icon: String
    @State private var creating = false
    @State private var errorMessage: String?

    init(initialTemplate: API.NewCustomApp.Template, onCreated: @escaping (API.CustomAppDetail) -> Void) {
        self.initialTemplate = initialTemplate
        self.onCreated = onCreated
        _template = State(initialValue: initialTemplate)
        let defaultIcon = AppsHomeLogic.starters.first(where: { $0.template == initialTemplate })?.defaultIcon ?? "dashboard"
        _icon = State(initialValue: defaultIcon)
    }

    var body: some View {
        let p = theme.palette
        let effectiveSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let slugError = effectiveSlug.isEmpty ? nil : AppsHomeLogic.validateSlug(effectiveSlug)
        let canSubmit = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !effectiveSlug.isEmpty
            && slugError == nil
            && !creating

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New custom app")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(p.secondaryText)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Starter template").font(.caption).foregroundStyle(p.secondaryText)
                Picker("Starter template", selection: $template) {
                    ForEach(AppsHomeLogic.starters) { s in
                        Text(s.label).tag(s.template)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: template) { _, next in
                    if let spec = AppsHomeLogic.starters.first(where: { $0.template == next }) {
                        icon = spec.defaultIcon
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(p.secondaryText)
                TextField(
                    template == .ledger ? "Finance" : template == .tracker ? "Reading Tracker" : "My App",
                    text: $name
                )
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, next in
                    if !slugTouched {
                        slug = AppsHomeLogic.slugify(next)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Slug").font(.caption).foregroundStyle(p.secondaryText)
                HStack(spacing: 4) {
                    Text("/apps/")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                    TextField("finance", text: $slug)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: slug) { _, next in
                            let lowered = next.lowercased()
                            if lowered != next { slug = lowered }
                        }
                        .onSubmit {
                            slugTouched = true
                        }
                }
                if let slugError {
                    Text(slugError)
                        .font(.caption)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                } else {
                    Text("URL path under /apps/ and space identifier.")
                        .font(.caption)
                        .foregroundStyle(p.tertiaryText)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption).foregroundStyle(p.secondaryText)
                TextField("Optional one-line summary of what this app tracks or does", text: $description)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon").font(.caption).foregroundStyle(p.secondaryText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(AppsHomeLogic.icons, id: \.self) { ic in
                        let selected = icon == ic
                        Button {
                            icon = ic
                        } label: {
                            Image(systemName: SidebarIcons.symbolName(ic))
                                .font(.system(size: 14))
                                .foregroundStyle(selected ? p.accent : p.secondaryText)
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .background(selected ? p.selected : p.surface, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? p.accent : p.border))
                        }
                        .buttonStyle(.plain)
                        .help(ic)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(creating)
                Button(creating ? "Creating\u{2026}" : "Create app") {
                    create(effectiveSlug: effectiveSlug)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func create(effectiveSlug: String) {
        creating = true
        errorMessage = nil
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { creating = false }
            do {
                let created = try await context.store.mutate(
                    API.createCustomApp(body: API.NewCustomApp(
                        description: desc.isEmpty ? nil : desc,
                        icon: icon,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        slug: effectiveSlug,
                        template: template
                    )),
                    invalidating: QueryInvalidation(resources: ["custom_apps"])
                )
                onCreated(created)
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
