import AppKit
import SwiftUI
import VesperCore

/// Native internal Browser screen: slim single-row omnibox + Vesper integration controls above an
/// isolated `WKWebView`, paired with an Arc-style compact left sidebar (`BrowserSidebarView`) and
/// Vesper's default right-hand Companion Chat inspector.
struct BrowserScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @State private var omniboxText = ""
    @State private var isEditingOmnibox = false
    @FocusState private var omniboxFocused: Bool
    @State private var sharePopoverOpen = false
    @State private var shieldPopoverOpen = false
    @State private var askPrompt = ""
    @State private var shareUntil = "page"
    @State private var shareIncludeScreenshot = true
    @State private var selectedShareTarget = "companion"
    @State private var isSubmittingAction = false

    private static let savedLinksRequest = API.listLibraryItems(kind: .link, offset: 0)

    private var store: BrowserStore? {
        context.window()?.app.browser
    }

    var body: some View {
        Group {
            if let store {
                browserContent(store: store)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            attachToShell()
            handleIncomingQueryURL()
        }
        .onDisappear {
            context.find.searcher = nil
        }
        .onChange(of: context.match) { _, _ in
            handleIncomingQueryURL()
        }
    }

    @ViewBuilder
    private func browserContent(store: BrowserStore) -> some View {
        let activeTab = store.activeTab
        VStack(spacing: 0) {
            omniboxBar(store: store, tab: activeTab)
            if let tab = activeTab, tab.isLoading {
                GeometryReader { geo in
                    Rectangle()
                        .fill(theme.palette.accent)
                        .frame(width: max(12, geo.size.width * min(1, max(0.05, tab.estimatedProgress))), height: 2)
                        .animation(.easeOut(duration: 0.15), value: tab.estimatedProgress)
                }
                .frame(height: 2)
            } else {
                Divider().opacity(0.45)
            }

            ZStack(alignment: .top) {
                if let tab = activeTab {
                    if tab.hasLoadedPage {
                        BrowserWebViewContainer(webView: tab.webView)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay {
                                if let error = tab.loadError {
                                    loadErrorOverlay(error: error, tab: tab)
                                }
                            }
                    } else {
                        newTabStartPage(store: store, tab: tab)
                    }
                } else {
                    Color.clear
                }

                if isEditingOmnibox {
                    omniboxSuggestionsOverlay(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: store.activeTab?.id) { _, _ in
            syncActiveTabChrome(store: store)
        }
        .onChange(of: store.activeTab?.urlString) { _, _ in
            syncActiveTabChrome(store: store)
        }
        .onChange(of: store.activeTab?.title) { _, _ in
            syncActiveTabChrome(store: store)
        }
        .onChange(of: store.focusAddressBarTick) { _, _ in
            focusOmnibox(store: store)
        }
        .onChange(of: omniboxFocused) { _, focused in
            isEditingOmnibox = focused
            if focused {
                omniboxText = store.activeTab?.urlString ?? ""
            } else {
                syncOmniboxDisplay(store: store)
            }
        }
        .task {
            syncActiveTabChrome(store: store)
            context.store.load(Self.savedLinksRequest)
            await store.refreshExtensionConfig()
        }
    }

    // MARK: Slim Single-Row Omnibox Bar

    private func omniboxBar(store: BrowserStore, tab: BrowserTabSession?) -> some View {
        HStack(spacing: 6) {
            // Back / Forward / Reload
            HStack(spacing: 2) {
                barIconButton("chevron.left", help: "Back (⌘[)", disabled: !(tab?.canGoBack ?? false)) {
                    tab?.goBack()
                }
                barIconButton("chevron.right", help: "Forward (⌘])", disabled: !(tab?.canGoForward ?? false)) {
                    tab?.goForward()
                }
                barIconButton(
                    (tab?.isLoading ?? false) ? "xmark" : "arrow.clockwise",
                    help: (tab?.isLoading ?? false) ? "Stop Loading" : "Reload (⌘R)",
                    disabled: !(tab?.hasLoadedPage ?? false)
                ) {
                    if tab?.isLoading == true { tab?.stopLoading() } else { tab?.reload() }
                }
            }

            // Address / Search Field
            HStack(spacing: 6) {
                Button {
                    shieldPopoverOpen.toggle()
                } label: {
                    let adBlockActive = store.isAdBlockActive(for: tab?.urlString ?? "")
                    Image(systemName: tab?.isPrivate == true ? "eye.slash.fill" : (adBlockActive ? "shield.lefthalf.filled" : "shield.slash"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(
                            tab?.isPrivate == true
                                ? Color.purple
                                : (adBlockActive ? theme.palette.accent : theme.palette.tertiaryText)
                        )
                }
                .buttonStyle(.plain)
                .hoverTooltip("Privacy, Ad-Block & Browser Settings")
                .popover(isPresented: $shieldPopoverOpen, arrowEdge: .bottom) {
                    shieldPopover(store: store, tab: tab)
                }

                if tab?.hasOnlySecureContent == true, !isEditingOmnibox {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.palette.tertiaryText)
                }

                TextField("Search \(store.searchEngine.label) or enter website", text: $omniboxText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($omniboxFocused)
                    .onSubmit {
                        let query = omniboxText
                        omniboxFocused = false
                        store.navigateActiveTab(input: query)
                    }
                    .onExitCommand {
                        omniboxFocused = false
                        syncOmniboxDisplay(store: store)
                    }

                if isEditingOmnibox, !omniboxText.isEmpty {
                    Button {
                        omniboxText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }

                if let tab, tab.hasLoadedPage, !isEditingOmnibox {
                    if abs(tab.zoom - 1.0) >= 0.05 {
                        Button("\(Int((tab.zoom * 100).rounded()))%") {
                            store.resetZoom(for: tab)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.palette.secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(theme.palette.hover))
                        .hoverTooltip("Reset zoom (⌘0)")
                    }

                    Button {
                        Task { await tab.toggleReaderMode(darkMode: colorScheme == .dark) }
                    } label: {
                        Image(systemName: tab.isReaderMode ? "doc.plaintext.fill" : "doc.plaintext")
                            .font(.system(size: 11.5))
                            .foregroundStyle(tab.isReaderMode ? theme.palette.accent : theme.palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip("Toggle Reader Mode (⌥⌘R)")

                    let bookmarked = store.isBookmarked(tab.urlString)
                    Button {
                        store.toggleBookmark(for: tab)
                    } label: {
                        Image(systemName: bookmarked ? "star.fill" : "star")
                            .font(.system(size: 11.5))
                            .foregroundStyle(bookmarked ? Color.yellow : theme.palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip(bookmarked ? "Remove Bookmark" : "Bookmark Page")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(omniboxFocused ? theme.palette.accent.opacity(0.75) : theme.palette.border.opacity(0.6), lineWidth: 1)
                    )
            )

            // Vesper Actions: Share with Persona, Screenshot, Clip, Open in Safari
            if let tab {
                sharePillButton(store: store, tab: tab)

                Menu {
                    Button {
                        Task { await store.screenshotToKnowledge(tab: tab) }
                    } label: {
                        Label("Screenshot to Knowledge Note", systemImage: "book")
                    }
                    Button {
                        Task { await store.screenshotToChat(tab: tab) }
                    } label: {
                        Label("Screenshot to Chat…", systemImage: "bubble.left")
                    }
                    Button {
                        Task { await store.copyScreenshot(tab: tab) }
                    } label: {
                        Label("Copy Page Screenshot", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button {
                        Task { await store.saveFullPagePDF(tab: tab) }
                    } label: {
                        Label("Save Full-Page PDF…", systemImage: "doc.richtext")
                    }
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.secondaryText)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!tab.hasLoadedPage)
                .hoverTooltip("Capture Page Screenshot or PDF")

                Menu {
                    Button {
                        Task { await store.clipToKnowledge(tab: tab, includeSelectionOnlyIfPresent: true) }
                    } label: {
                        Label("Clip Page / Selection to Knowledge", systemImage: "book")
                    }
                    Button {
                        Task { await store.saveToReadingList(tab: tab) }
                    } label: {
                        Label("Save Link to Reading List", systemImage: "bookmark")
                    }
                    Button {
                        Task { await store.copyMarkdownQuote(tab: tab) }
                    } label: {
                        Label("Copy Markdown Quote", systemImage: "text.quote")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.secondaryText)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!tab.hasLoadedPage)
                .hoverTooltip("Clip to Knowledge or Save Link")

                barIconButton("safari", help: "Open in Safari (⌥⌘O)", disabled: !tab.hasLoadedPage) {
                    if let url = URL(string: tab.urlString), BrowserURLResolver.isWebURL(url) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.palette.background)
    }

    private func barIconButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? theme.palette.tertiaryText.opacity(0.45) : theme.palette.secondaryText)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .hoverTooltip(help)
    }

    // MARK: Share With Persona Pill & Popover

    private func sharePillButton(store: BrowserStore, tab: BrowserTabSession) -> some View {
        let isSharing = tab.activeShare != nil
        let check = store.pageShareCheck(for: tab)
        return Button {
            sharePopoverOpen.toggle()
            if sharePopoverOpen {
                Task { await store.refreshExtensionConfig() }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(isSharing ? Color.orange : (check.ok ? Color.secondary.opacity(0.45) : Color.red.opacity(0.45)))
                    .frame(width: 7, height: 7)
                Text(isSharing ? "Sharing" : "Share")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isSharing ? Color.orange : theme.palette.text)
                if let reads = tab.activeShare?.reads.count, reads > 0 {
                    Text("\(reads)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(Color.orange)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isSharing ? Color.orange.opacity(0.14) : theme.palette.surface)
                    .overlay(Capsule().stroke(isSharing ? Color.orange.opacity(0.45) : theme.palette.border.opacity(0.55), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .disabled(!tab.hasLoadedPage)
        .hoverTooltip(isSharing ? "Manage live tab share with persona" : "Share this tab or ask a persona")
        .popover(isPresented: $sharePopoverOpen, arrowEdge: .bottom) {
            sharePopover(store: store, tab: tab)
        }
    }

    private func sharePopover(store: BrowserStore, tab: BrowserTabSession) -> some View {
        let check = store.pageShareCheck(for: tab)
        let actions = BrowserPageGuard.siteActions(url: tab.urlString, personas: store.extensionConfig.personas)
        let companionChatId = context.window()?.companionChatId

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let share = tab.activeShare {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(Color.orange).frame(width: 8, height: 8)
                            Text("Sharing this tab")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button("Open Companion") {
                                context.window()?.openCompanionChat(share.chatId)
                                sharePopoverOpen = false
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11.5))
                        }
                        Text("With \"\(share.chatTitle.isEmpty ? "chat" : share.chatTitle)\", \(share.until == "page" ? "until you leave this page" : "until you stop"). \(share.includeScreenshot ? "Text + screenshot." : "Text only.")")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)

                        if !share.reads.isEmpty {
                            Text("Read log")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            ForEach(Array(share.reads.prefix(5).enumerated()), id: \.offset) { _, read in
                                HStack {
                                    Text("\(read.persona.isEmpty ? "Persona" : read.persona) read it")
                                        .font(.system(size: 11))
                                    Spacer()
                                    Text(read.readAt.prefix(19).replacingOccurrences(of: "T", with: " "))
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("Not read by persona yet.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Button("Send Snapshot Now") {
                                Task { await store.sendSnapshot(for: tab) }
                            }
                            .controlSize(.small)
                            Spacer()
                            Button("Stop Sharing") {
                                Task { await store.stopShare(for: tab, reason: "person") }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                } else if !check.ok {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Can't share this page", systemImage: "hand.raised")
                            .font(.system(size: 13, weight: .semibold))
                        Text(check.reason ?? "This page is blocked from sharing.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        if check.isUserBlocked, let host = check.host {
                            Button("Allow sharing \(host) again") {
                                Task { await store.removeNeverShare(host: host) }
                            }
                            .controlSize(.small)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Let a persona see this tab")
                            .font(.system(size: 13, weight: .semibold))

                        Picker("Share with", selection: $selectedShareTarget) {
                            Text(companionChatId != nil ? "Current Companion Chat" : "New Companion Chat").tag("companion")
                            ForEach(store.extensionConfig.personas) { p in
                                Text("New chat with \(p.name)").tag("persona:\(p.id)")
                            }
                            if !store.extensionConfig.chats.isEmpty {
                                Divider()
                                ForEach(store.extensionConfig.chats.prefix(8)) { c in
                                    Text(c.title.isEmpty ? "Untitled chat" : c.title).tag("chat:\(c.id)")
                                }
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)

                        Toggle("Include visible screenshot", isOn: $shareIncludeScreenshot)
                            .font(.system(size: 11.5))

                        Picker("Duration", selection: $shareUntil) {
                            Text("Until I leave this page").tag("page")
                            Text("Until I press Stop").tag("stop")
                        }
                        .pickerStyle(.radioGroup)
                        .font(.system(size: 11.5))

                        Text("Form fields, passwords, and card numbers are never sent. The persona can read this tab, not click or type in it.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)

                        Button {
                            isSubmittingAction = true
                            Task {
                                defer { isSubmittingAction = false }
                                let (chatId, personaId) = resolveShareTarget(
                                    selection: selectedShareTarget,
                                    companionChatId: companionChatId,
                                    personas: store.extensionConfig.personas
                                )
                                await store.startShare(
                                    for: tab,
                                    chatId: chatId,
                                    personaId: personaId,
                                    until: shareUntil,
                                    includeScreenshot: shareIncludeScreenshot,
                                    openInCompanion: true
                                )
                            }
                        } label: {
                            Text("Share with Persona")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isSubmittingAction)
                    }
                }

                if check.ok {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quick Ask")
                            .font(.system(size: 12, weight: .semibold))
                        TextField("Ask about this page or selection…", text: $askPrompt)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .onSubmit {
                                submitAsk(store: store, tab: tab)
                            }
                        HStack {
                            Button("Ask in Companion") {
                                submitAsk(store: store, tab: tab)
                            }
                            .controlSize(.small)
                            .disabled(isSubmittingAction)
                            Spacer()
                        }

                        if !actions.isEmpty {
                            Text("For this page")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            ForEach(actions) { act in
                                Button(act.label) {
                                    sharePopoverOpen = false
                                    Task {
                                        await store.askAboutPage(tab: tab, prompt: act.prompt, personaId: act.personaId, openInCompanion: true)
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    if let host = check.host {
                        Divider()
                        Button("Never share \(host)") {
                            Task { await store.addNeverShare(host: host) }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 310)
        .frame(maxHeight: 460)
    }

    private func resolveShareTarget(
        selection: String,
        companionChatId: String?,
        personas: [BrowserExtensionPersona]
    ) -> (chatId: String?, personaId: String?) {
        if selection == "companion" {
            if let companionChatId { return (companionChatId, nil) }
            let def = personas.first(where: \.isDefault) ?? personas.first
            return (nil, def?.id)
        }
        if selection.hasPrefix("chat:") {
            return (String(selection.dropFirst(5)), nil)
        }
        if selection.hasPrefix("persona:") {
            return (nil, String(selection.dropFirst(8)))
        }
        return (companionChatId, nil)
    }

    private func submitAsk(store: BrowserStore, tab: BrowserTabSession) {
        let prompt = askPrompt
        askPrompt = ""
        sharePopoverOpen = false
        let def = store.extensionConfig.personas.first(where: \.isDefault) ?? store.extensionConfig.personas.first
        Task {
            await store.askAboutPage(tab: tab, prompt: prompt, personaId: def?.id, openInCompanion: true)
        }
    }

    // MARK: Shield / Ad-Block / Browser Settings Popover

    private func shieldPopover(store: BrowserStore, tab: BrowserTabSession?) -> some View {
        let host = tab.flatMap { BrowserPageGuard.normalizeHost($0.urlString) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Browser Privacy & Controls")
                .font(.system(size: 13, weight: .semibold))

            Toggle("Block Ads & Trackers (WebKit)", isOn: Binding(
                get: { store.adBlockEnabled },
                set: { store.setAdBlockEnabled($0) }
            ))
            .font(.system(size: 12))

            if let host, store.adBlockEnabled {
                let active = store.isAdBlockActive(for: tab?.urlString ?? "")
                Toggle("Protect \(host)", isOn: Binding(
                    get: { active },
                    set: { _ in store.toggleAdBlock(forHost: host) }
                ))
                .font(.system(size: 12))
            }

            Divider()

            Toggle("Open Vesper links in Browser", isOn: Binding(
                get: { store.openExternalLinksInBrowser },
                set: {
                    store.openExternalLinksInBrowser = $0
                    store.scheduleSave()
                }
            ))
            .font(.system(size: 12))
            Text("Hold ⌥ while clicking any link to open it in Safari.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            HStack {
                Text("Search engine")
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: Binding(
                    get: { store.searchEngine },
                    set: {
                        store.searchEngine = $0
                        store.scheduleSave()
                    }
                )) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .controlSize(.small)
            }

            Divider()

            HStack {
                Button("Clear Cookies & Cache", role: .destructive) {
                    shieldPopoverOpen = false
                    Task { await store.clearBrowsingData() }
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: Omnibox Autocomplete Overlay

    @ViewBuilder
    private func omniboxSuggestionsOverlay(store: BrowserStore) -> some View {
        let savedItems = (context.store.entry(Self.savedLinksRequest).data?.items ?? []).compactMap { item -> (id: String, title: String, url: String, site: String?)? in
            guard let url = item.url, !url.isEmpty else { return nil }
            return (item.id, item.title, url, item.site)
        }
        let suggestions = BrowserTabListLogic.suggestions(
            query: omniboxText,
            openTabs: store.tabs.map(\.record),
            bookmarks: store.bookmarks,
            savedLinks: savedItems,
            history: store.history,
            limit: 8
        )
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(suggestions) { s in
                    Button {
                        omniboxFocused = false
                        if let tabId = s.tabId {
                            store.selectTab(tabId)
                        } else if let url = URL(string: s.url) {
                            store.openURL(url, inNewTab: false)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: suggestionSymbol(s.kind))
                                .font(.system(size: 11))
                                .foregroundStyle(theme.palette.secondaryText)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.palette.text)
                                    .lineLimit(1)
                                Text(s.subtitle)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(theme.palette.tertiaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.palette.surface)
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border, lineWidth: 1))
            )
            .padding(.horizontal, 48)
            .padding(.top, 4)
        }
    }

    private func suggestionSymbol(_ kind: BrowserOmniboxSuggestion.Kind) -> String {
        switch kind {
        case .openTab: "macwindow"
        case .bookmark: "star.fill"
        case .savedLink: "bookmark"
        case .history: "clock"
        }
    }

    // MARK: Start Page & Error Overlay

    private func newTabStartPage(store: BrowserStore, tab: BrowserTabSession) -> some View {
        let savedItems = context.store.entry(Self.savedLinksRequest).data?.items ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: tab.isPrivate ? "eye.slash" : "safari")
                            .font(.system(size: 22))
                            .foregroundStyle(tab.isPrivate ? Color.purple : theme.palette.accent)
                        Text(tab.isPrivate ? "Private Tab" : "Vesper Browser")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(theme.palette.text)
                    }
                    Text(
                        tab.isPrivate
                            ? "Cookies, cache, and history stay out of disk. Private tabs are never shared with personas."
                            : "Press ⌘L to type a URL or search · ⌘⌃1–9 to switch web tabs · ⌘\\ to open Companion Chat."
                    )
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.palette.secondaryText)
                }

                if !store.bookmarks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bookmarks")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.palette.secondaryText)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)], spacing: 10) {
                            ForEach(store.bookmarks.prefix(12)) { bm in
                                startPageCard(
                                    title: bm.title,
                                    subtitle: BrowserURLResolver.displayHost(for: bm.url),
                                    symbol: "star.fill"
                                ) {
                                    if let url = URL(string: bm.url) { tab.load(url) }
                                }
                            }
                        }
                    }
                }

                if !savedItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved Links")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.palette.secondaryText)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 250), spacing: 10)], spacing: 10) {
                            ForEach(savedItems.prefix(9), id: \.id) { item in
                                if let raw = item.url, let url = URL(string: raw) {
                                    startPageCard(
                                        title: item.title.isEmpty ? BrowserURLResolver.displayHost(for: raw) : item.title,
                                        subtitle: item.site?.isEmpty == false ? item.site! : BrowserURLResolver.displayHost(for: raw),
                                        symbol: "bookmark"
                                    ) {
                                        tab.load(url)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.background)
    }

    private func startPageCard(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.palette.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.palette.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.palette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border.opacity(0.55), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private func loadErrorOverlay(error: String, tab: BrowserTabSession) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(theme.palette.secondaryText)
            Text("Couldn't load page")
                .font(.system(size: 15, weight: .semibold))
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            HStack(spacing: 10) {
                Button("Retry") { tab.reload() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                if let url = URL(string: tab.urlString), BrowserURLResolver.isWebURL(url) {
                    Button("Open in Safari") { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.background.opacity(0.96))
    }

    // MARK: Shell Sync

    private func attachToShell() {
        guard let store else { return }
        context.sidebarView = AnyView(BrowserSidebarView(store: store, context: context))
        syncActiveTabChrome(store: store)
    }

    private func handleIncomingQueryURL() {
        guard let store, let raw = context.match.query["url"], let url = URL(string: raw), BrowserURLResolver.isWebURL(url) else {
            return
        }
        let inNewTab = context.match.query["newTab"] != "0"
        store.openURL(url, inNewTab: inNewTab, reuseExisting: true)
        // Strip the query param so revisiting the route via history doesn't re-open the URL.
        context.navigate("/browser", replace: true)
    }

    private func syncActiveTabChrome(store: BrowserStore) {
        let tab = store.activeTab
        context.find.searcher = tab?.webView
        context.chrome = NativeChrome(
            title: tab?.displayTitle ?? "Browser",
            subtitle: tab?.displayHost.isEmpty == false ? tab?.displayHost : nil,
            toolbarItems: [],
            inspector: nil
        )
        if !omniboxFocused {
            syncOmniboxDisplay(store: store)
        }
    }

    private func syncOmniboxDisplay(store: BrowserStore) {
        guard let tab = store.activeTab, tab.hasLoadedPage else {
            omniboxText = ""
            return
        }
        omniboxText = BrowserURLResolver.displayAddress(for: tab.urlString)
    }

    private func focusOmnibox(store: BrowserStore) {
        omniboxText = store.activeTab?.urlString ?? ""
        context.window()?.window?.makeFirstResponder(nil)
        omniboxFocused = true
    }
}
