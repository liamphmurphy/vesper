import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

/// Native internal Browser screen: slim single-row omnibox + WebExtensions + Keychain AutoFill +
/// Split View + Downloads + Vesper integration controls above isolated `WKWebView` panes.
struct BrowserScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @State private var omniboxText = ""
    @State private var isEditingOmnibox = false
    @State private var selectedSuggestionIndex: Int?
    @FocusState private var omniboxFocused: Bool

    @State private var sharePopoverOpen = false
    @State private var shieldPopoverOpen = false
    @State private var siteSecurityPopoverOpen = false
    @State private var autofillPopoverOpen = false
    @State private var extensionsPopoverOpen = false
    @State private var downloadsPopoverOpen = false
    @State private var knowledgePopoverOpen = false
    @State private var darkModePopoverOpen = false
    @State private var omniboxPeekVisible = false
    @State private var sidebarPeekVisible = false

    private var anyPopoverOpen: Bool {
        sharePopoverOpen || shieldPopoverOpen || siteSecurityPopoverOpen || autofillPopoverOpen || extensionsPopoverOpen || downloadsPopoverOpen || knowledgePopoverOpen || darkModePopoverOpen
    }

    @State private var askPrompt = ""
    @State private var shareUntil = "page"
    @State private var shareIncludeScreenshot = true
    @State private var selectedShareTarget = "companion"
    @State private var isSubmittingAction = false
    @State private var highlightColor: BrowserHighlightColor = .yellow
    @State private var highlightNote = ""
    @State private var multiTabSelection: Set<UUID> = []
    @State private var multiTabPickerExpanded = false

    private static let savedLinksRequest = API.listLibraryItems(kind: .link, offset: 0)
    private static let spacesRequest = API.listChatSpaces()

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
        let chromeAutoHidden = store.isFocusMode || store.layoutConfig.autoHideOmnibox
        let showOmnibox = !chromeAutoHidden || isEditingOmnibox || omniboxPeekVisible || anyPopoverOpen
        let canHoverPeekSidebar = store.layoutConfig.hoverPeekSidebar && (context.window()?.isSidebarCollapsed == true || store.isFocusMode)

        VStack(spacing: 0) {
            if showOmnibox {
                omniboxBar(store: store, tab: activeTab)
                    .onHover { hovering in
                        if chromeAutoHidden && !hovering && !isEditingOmnibox && !anyPopoverOpen {
                            omniboxPeekVisible = false
                        }
                    }
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
            }

            if let tab = activeTab, let pending = tab.pendingCredentialSave {
                savePasswordBanner(store: store, tab: tab, pending: pending)
                Divider().opacity(0.4)
            }

            if let tab = activeTab, tab.passkeyFallbackSuggested {
                passkeyFallbackBanner(store: store, tab: tab)
                Divider().opacity(0.4)
            }

            ZStack(alignment: .topLeading) {
                if store.isSplitViewActive, let left = store.primaryTab, let right = store.splitTab {
                    splitBrowserCanvas(store: store, left: left, right: right)
                } else if let tab = activeTab {
                    browserPane(store: store, tab: tab, pane: .primary, isSplit: false)
                } else {
                    Color.clear
                }

                // Top-edge hover sensor to peek the hidden omnibox in Auto-Hide / Focus Mode.
                if chromeAutoHidden && !showOmnibox {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 6)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                withAnimation(.easeOut(duration: 0.14)) {
                                    omniboxPeekVisible = true
                                }
                            }
                        }
                }

                // Arc-style left-edge hover-peek sidebar when the native sidebar is collapsed.
                if canHoverPeekSidebar && !sidebarPeekVisible {
                    Color.clear
                        .frame(width: 6)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    sidebarPeekVisible = true
                                }
                            }
                        }
                }

                if canHoverPeekSidebar && sidebarPeekVisible {
                    HStack(spacing: 0) {
                        BrowserSidebarView(store: store, context: context)
                            .frame(width: 215)
                            .frame(maxHeight: .infinity)
                            .background(theme.palette.surface)
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(theme.palette.border.opacity(0.65))
                                    .frame(width: 1)
                            }
                            .shadow(color: .black.opacity(0.28), radius: 14, x: 4, y: 0)
                            .onHover { hovering in
                                if !hovering {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        sidebarPeekVisible = false
                                    }
                                }
                            }
                        Spacer(minLength: 0)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                if isEditingOmnibox {
                    omniboxSuggestionsOverlay(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: store.isFocusMode) { _, focus in
            syncFocusModeToShell(focus)
            if !focus {
                omniboxPeekVisible = false
                sidebarPeekVisible = false
            }
        }
        .onChange(of: store.activeProfileId) { _, _ in
            syncActiveTabChrome(store: store)
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
        .onChange(of: store.openAutofillPopoverTick) { _, _ in
            autofillPopoverOpen = true
        }
        .onChange(of: store.openExtensionsPopoverTick) { _, _ in
            extensionsPopoverOpen = true
        }
        .onChange(of: store.openKnowledgePopoverTick) { _, _ in
            knowledgePopoverOpen = true
            Task { await store.refreshKnowledgeIndex(force: true) }
        }
        .onChange(of: omniboxFocused) { _, focused in
            isEditingOmnibox = focused
            selectedSuggestionIndex = nil
            if focused {
                omniboxText = store.activeTab?.urlString ?? ""
            } else {
                syncOmniboxDisplay(store: store)
            }
        }
        .onChange(of: omniboxText) { _, _ in
            selectedSuggestionIndex = nil
        }
        .task {
            syncActiveTabChrome(store: store)
            context.store.load(Self.savedLinksRequest)
            context.store.load(Self.spacesRequest)
            await store.refreshExtensionConfig()
            await store.refreshKnowledgeIndex()
            store.scheduleAutoFollowSync()
        }
    }

    // MARK: Split View & Single Pane Canvas

    private func splitBrowserCanvas(store: BrowserStore, left: BrowserTabSession, right: BrowserTabSession) -> some View {
        GeometryReader { geo in
            let dividerWidth: CGFloat = 5
            let usableWidth = max(200, geo.size.width - dividerWidth)
            let leftWidth = max(240, min(usableWidth - 240, usableWidth * CGFloat(store.splitRatio)))
            let rightWidth = max(240, usableWidth - leftWidth)

            HStack(spacing: 0) {
                browserPane(store: store, tab: left, pane: .primary, isSplit: true)
                    .frame(width: leftWidth)

                Rectangle()
                    .fill(theme.palette.border.opacity(0.65))
                    .frame(width: dividerWidth)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let proposed = (leftWidth + value.translation.width) / max(1, usableWidth)
                                store.setSplitRatio(Double(proposed))
                            }
                    )
                    .onTapGesture(count: 2) {
                        store.setSplitRatio(0.5)
                    }

                browserPane(store: store, tab: right, pane: .secondary, isSplit: true)
                    .frame(width: rightWidth)
            }
        }
    }

    private func browserPane(
        store: BrowserStore,
        tab: BrowserTabSession,
        pane: BrowserStore.SplitPane,
        isSplit: Bool
    ) -> some View {
        let isFocusedPane = !isSplit || store.focusedPane == pane
        return VStack(spacing: 0) {
            if isSplit {
                splitPaneHeader(store: store, tab: tab, pane: pane, isFocused: isFocusedPane)
                Divider().opacity(0.35)
            }
            ZStack {
                if tab.hasLoadedPage {
                    BrowserWebViewContainer(webView: tab.webView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if let fallbackURL = tab.pendingHTTPSFallbackURL {
                                httpsFallbackOverlay(fallbackURL: fallbackURL, store: store, tab: tab)
                            } else if let tlsError = tab.tlsErrorMessage {
                                tlsErrorOverlay(error: tlsError, tab: tab)
                            } else if let error = tab.loadError {
                                loadErrorOverlay(error: error, tab: tab)
                            }
                        }
                        .overlay {
                            if store.regionCaptureTabId == tab.id {
                                BrowserRegionCaptureOverlay(
                                    onCapture: { rect, destination in
                                        Task { await store.completeRegionCapture(tab: tab, rect: rect, destination: destination) }
                                    },
                                    onCancel: { store.cancelRegionCapture() }
                                )
                            }
                        }
                } else {
                    newTabStartPage(store: store, tab: tab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(
            Rectangle()
                .stroke(isSplit && isFocusedPane ? theme.palette.accent.opacity(0.55) : Color.clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                if isSplit && store.focusedPane != pane {
                    store.focusSplitPane(pane)
                }
            }
        )
    }

    private func splitPaneHeader(
        store: BrowserStore,
        tab: BrowserTabSession,
        pane: BrowserStore.SplitPane,
        isFocused: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isFocused ? theme.palette.accent : theme.palette.tertiaryText.opacity(0.35))
                .frame(width: 6, height: 6)
            if let icon = tab.favicon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            Text(tab.displayTitle)
                .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                .foregroundStyle(isFocused ? theme.palette.text : theme.palette.secondaryText)
                .lineLimit(1)
            if !tab.displayHost.isEmpty {
                Text(tab.displayHost)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if pane == .secondary {
                Button {
                    store.swapSplitPanes()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.palette.secondaryText)
                }
                .buttonStyle(.plain)
                .hoverTooltip("Swap Split Panes")

                Button {
                    store.closeSplitView()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.palette.secondaryText)
                }
                .buttonStyle(.plain)
                .hoverTooltip("Close Split View (⌘⌃\\)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isFocused ? theme.palette.surface : theme.palette.background)
        .contentShape(Rectangle())
        .onTapGesture { store.focusSplitPane(pane) }
    }

    // MARK: Save Password Banner

    private func savePasswordBanner(
        store: BrowserStore,
        tab: BrowserTabSession,
        pending: BrowserPendingCredentialSave
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.accent)
            Text(
                pending.isUpdate
                    ? "Update saved Keychain password for **\(pending.username)** on **\(pending.host)**?"
                    : "Save password for **\(pending.username)** on **\(pending.host)** in macOS Keychain?"
            )
            .font(.system(size: 11.5))
            .lineLimit(1)
            Spacer(minLength: 6)
            Button("Never") {
                store.neverSavePasswords(for: pending.host, tab: tab)
            }
            .controlSize(.small)
            Button("Not Now") {
                store.dismissPendingCredential(for: tab)
            }
            .controlSize(.small)
            Button(pending.isUpdate ? "Update" : "Save") {
                store.savePendingCredential(for: tab)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.palette.surface)
    }

    private func passkeyFallbackBanner(store: BrowserStore, tab: BrowserTabSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text("This site requested a **Passkey**, which requires Safari on macOS.")
                .font(.system(size: 11.5))
                .lineLimit(1)
            Spacer(minLength: 6)
            Button("Dismiss") {
                tab.passkeyFallbackSuggested = false
            }
            .controlSize(.small)
            Button("Open in Safari") {
                tab.passkeyFallbackSuggested = false
                if let url = URL(string: tab.urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private func httpsFallbackOverlay(fallbackURL: URL, store: BrowserStore, tab: BrowserTabSession) -> some View {
        let host = fallbackURL.host ?? fallbackURL.absoluteString
        return VStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Secure Connection Unavailable")
                .font(.system(size: 16, weight: .semibold))
            Text("HTTPS-Only Mode couldn't connect securely to **\(host)**. Continuing over plain HTTP exposes traffic on this network.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Go Back") {
                    tab.pendingHTTPSFallbackURL = nil
                    if tab.canGoBack { tab.goBack() }
                }
                .buttonStyle(.borderedProminent)
                Button("Continue to HTTP for \(host)") {
                    store.allowHTTPFallback(for: tab)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.background)
    }

    private func tlsErrorOverlay(error: String, tab: BrowserTabSession) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 34))
                .foregroundStyle(.red)
            Text("Connection Is Not Private")
                .font(.system(size: 16, weight: .semibold))
            Text("WebKit rejected the TLS certificate for **\(tab.displayHost.isEmpty ? "this site" : tab.displayHost)**.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text(error)
                .font(.system(size: 11.5).monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button("Go Back") {
                    tab.tlsErrorMessage = nil
                    if tab.canGoBack { tab.goBack() }
                }
                .buttonStyle(.borderedProminent)
                Button("Reload") {
                    tab.reload()
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.background)
    }

    // MARK: Slim Single-Row Omnibox Bar

    private func omniboxBar(store: BrowserStore, tab: BrowserTabSession?) -> some View {
        let downloads = WebDownloads.shared
        let matchingCreds = tab.map { store.autofill.matchingCredentials(for: $0.urlString) } ?? []
        let canAutofill = tab.map {
            BrowserAutofillLogic.canAutofill(urlString: $0.urlString, hasOnlySecureContent: $0.hasOnlySecureContent)
        } ?? false
        let loadedExtensions = store.extensionHost.toolbarItems.filter { $0.isEnabled && $0.isLoaded }

        return HStack(spacing: 6) {
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
                    let hits = tab?.adBlockInterventionsCount ?? 0
                    HStack(spacing: 3) {
                        Image(systemName: tab?.isPrivate == true ? "eye.slash.fill" : (adBlockActive ? "shield.lefthalf.filled" : "shield.slash"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(
                                tab?.isPrivate == true
                                    ? Color.purple
                                    : (adBlockActive ? theme.palette.accent : theme.palette.tertiaryText)
                            )
                        if adBlockActive, hits > 0, tab?.isPrivate != true {
                            Text(hits > 99 ? "99+" : "\(hits)")
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(theme.palette.accent)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 0.5)
                                .background(Capsule().fill(theme.palette.accent.opacity(0.14)))
                        }
                    }
                }
                .buttonStyle(.plain)
                .hoverTooltip("Privacy, Ad-Block & Browser Settings")
                .popover(isPresented: $shieldPopoverOpen, arrowEdge: .bottom) {
                    BrowserShieldPopover(store: store, tab: tab, isPresented: $shieldPopoverOpen)
                }

                if let tab, tab.hasLoadedPage, !isEditingOmnibox {
                    siteSecurityButton(store: store, tab: tab)
                }

                if let tab, tab.isCapturingMedia, !isEditingOmnibox {
                    Button {
                        tab.stopMediaCapture()
                        store.showToast("Stopped camera & microphone access", tone: .neutral)
                    } label: {
                        HStack(spacing: 3) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Image(systemName: tab.cameraCaptureState == .active ? "video.fill" : "mic.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.red.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip("Camera or microphone active — click to stop")
                }

                TextField("Search \(store.searchEngine.label) or enter website", text: $omniboxText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($omniboxFocused)
                    .onSubmit {
                        submitOmnibox(store: store)
                    }
                    .onExitCommand {
                        omniboxFocused = false
                        selectedSuggestionIndex = nil
                        syncOmniboxDisplay(store: store)
                    }
                    .onKeyPress(.downArrow) {
                        guard isEditingOmnibox else { return .ignored }
                        let count = currentSuggestions(store: store).count
                        guard count > 0 else { return .ignored }
                        selectedSuggestionIndex = selectedSuggestionIndex.map { ($0 + 1) % count } ?? 0
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard isEditingOmnibox else { return .ignored }
                        let count = currentSuggestions(store: store).count
                        guard count > 0 else { return .ignored }
                        selectedSuggestionIndex = selectedSuggestionIndex.map { ($0 - 1 + count) % count } ?? (count - 1)
                        return .handled
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

                    // Knowledge Backlinks & Persistent Highlights badge
                    let backlinks = store.backlinks(for: tab.urlString)
                    let pageHighlights = store.highlights(for: tab.urlString)
                    let noteCount = backlinks.count
                    let highlightCount = pageHighlights.count
                    let hasExactBacklink = backlinks.contains(where: { $0.matchKind == .exactURL })
                    Button {
                        knowledgePopoverOpen.toggle()
                        if knowledgePopoverOpen {
                            Task { await store.refreshKnowledgeIndex(force: true) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: (hasExactBacklink || highlightCount > 0) ? "book.closed.fill" : "book.closed")
                                .font(.system(size: 11))
                                .foregroundStyle(
                                    (hasExactBacklink || highlightCount > 0)
                                        ? theme.palette.accent
                                        : (noteCount > 0 ? theme.palette.secondaryText : theme.palette.tertiaryText)
                                )
                            if noteCount > 0 || highlightCount > 0 {
                                let badgeCount = noteCount + highlightCount
                                Text("\(badgeCount)")
                                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle((hasExactBacklink || highlightCount > 0) ? theme.palette.accent : theme.palette.secondaryText)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 0.5)
                                    .background(Capsule().fill(((hasExactBacklink || highlightCount > 0) ? theme.palette.accent : theme.palette.secondaryText).opacity(0.14)))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip(
                        noteCount > 0 || highlightCount > 0
                            ? "Knowledge Backlinks (\(noteCount)) & Highlights (\(highlightCount))"
                            : "Knowledge Backlinks & Web Highlights (⌘⇧H)"
                    )
                    .popover(isPresented: $knowledgePopoverOpen, arrowEdge: .bottom) {
                        knowledgeBacklinksPopover(store: store, tab: tab)
                    }

                    // Keychain AutoFill icon
                    Button {
                        autofillPopoverOpen.toggle()
                    } label: {
                        Image(systemName: "key.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(
                                (tab.hasLoginForm || !matchingCreds.isEmpty) && canAutofill
                                    ? theme.palette.accent
                                    : theme.palette.tertiaryText
                            )
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip("Keychain AutoFill & Password Generator (⌘⇧A)")
                    .popover(isPresented: $autofillPopoverOpen, arrowEdge: .bottom) {
                        autofillPopover(store: store, tab: tab)
                    }

                    Button {
                        darkModePopoverOpen.toggle()
                    } label: {
                        let dmApplied = tab.darkModeStatus == .applied
                        let dmNative = tab.darkModeStatus == .skippedNative
                        Image(systemName: dmApplied ? "moon.stars.fill" : (dmNative ? "moon.fill" : "moon.stars"))
                            .font(.system(size: 11))
                            .foregroundStyle(
                                dmApplied
                                    ? theme.palette.accent
                                    : (dmNative ? theme.palette.secondaryText : theme.palette.tertiaryText)
                            )
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip(
                        tab.darkModeStatus == .applied
                            ? "Auto Dark Mode: Active (⌥⌘D)"
                            : (tab.darkModeStatus == .skippedNative
                                ? "Auto Dark Mode: Native dark site detected (⌥⌘D)"
                                : "Auto Dark Mode (⌥⌘D)")
                    )
                    .popover(isPresented: $darkModePopoverOpen, arrowEdge: .bottom) {
                        BrowserDarkModePopover(store: store, tab: tab)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(omniboxFocused ? theme.palette.accent.opacity(0.75) : theme.palette.border.opacity(0.6), lineWidth: 1)
                    )
            )

            // WebExtensions Toolbar Strip + Manager
            HStack(spacing: 3) {
                ForEach(loadedExtensions.prefix(3)) { ext in
                    Button {
                        store.extensionHost.performAction(for: ext.id)
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            if let icon = ext.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 15, height: 15)
                            } else {
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(theme.palette.secondaryText)
                            }
                            if !ext.badgeText.isEmpty {
                                Text(ext.badgeText.prefix(4))
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 2.5)
                                    .background(Capsule().fill(theme.palette.accent))
                                    .offset(x: 4, y: 3)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!ext.actionEnabled)
                    .hoverTooltip(ext.actionLabel)
                }

                Button {
                    extensionsPopoverOpen.toggle()
                } label: {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(loadedExtensions.isEmpty ? theme.palette.secondaryText : theme.palette.accent)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTooltip("WebExtensions Manager (⌘⌃E)")
                .popover(isPresented: $extensionsPopoverOpen, arrowEdge: .bottom) {
                    extensionsManagerPopover(store: store)
                }
            }
            .background(
                BrowserExtensionPopupAnchor { view in
                    store.extensionHost.popupAnchorView = view
                }
                .frame(width: 1, height: 1)
            )

            // Split View Toggle
            Button {
                store.toggleSplitView()
            } label: {
                Image(systemName: store.isSplitViewActive ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(store.isSplitViewActive ? theme.palette.accent : theme.palette.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTooltip(store.isSplitViewActive ? "Close Split View (⌘⌃\\)" : "Split View Side-by-Side (⌘⌃\\)")

            // Focus Mode Toggle
            Button {
                store.toggleFocusMode()
            } label: {
                Image(systemName: store.isFocusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(store.isFocusMode ? theme.palette.accent : theme.palette.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTooltip(store.isFocusMode ? "Exit Focus Mode (⌘⇧F)" : "Focus Mode — Hide Chrome (⌘⇧F)")

            // Downloads indicator (shown when downloads exist)
            if !downloads.recentDownloads.isEmpty {
                Button {
                    downloadsPopoverOpen.toggle()
                } label: {
                    Image(systemName: downloads.hasActiveDownloads ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(downloads.hasActiveDownloads ? theme.palette.accent : theme.palette.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTooltip("Recent Downloads")
                .popover(isPresented: $downloadsPopoverOpen, arrowEdge: .bottom) {
                    downloadsPopover(downloads: downloads)
                }
            }

            // Vesper Actions: Share with Persona, Screenshot (Viewport + Region), Clip, Open in Safari
            if let tab {
                sharePillButton(store: store, tab: tab)

                Menu {
                    Button {
                        Task { await store.screenshotToKnowledge(tab: tab) }
                    } label: {
                        Label("Screenshot to Knowledge Note", systemImage: "book")
                    }
                    Button {
                        store.beginRegionCapture(for: tab)
                    } label: {
                        Label("Capture Region Screenshot…", systemImage: "crop")
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
                .hoverTooltip("Capture Page / Region Screenshot or PDF")

                Menu {
                    let clipDest = BrowserSpaceRoutingLogic.clipFolder(for: store.boundSpaceSummary(for: tab))
                    Button {
                        Task { await store.highlightSelection(in: tab, color: highlightColor) }
                    } label: {
                        Label("Highlight Selection to Knowledge (⌘⇧H)", systemImage: "highlighter")
                    }
                    Button {
                        Task { await store.clipToKnowledge(tab: tab, includeSelectionOnlyIfPresent: true) }
                    } label: {
                        Label("Clip Page / Selection › \(clipDest)", systemImage: "book")
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
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(theme.palette.background)
    }

    private func submitOmnibox(store: BrowserStore) {
        let suggestions = currentSuggestions(store: store)
        if let idx = selectedSuggestionIndex, suggestions.indices.contains(idx) {
            let picked = suggestions[idx]
            omniboxFocused = false
            selectedSuggestionIndex = nil
            if let tabId = picked.tabId {
                store.selectTab(tabId)
            } else if let url = URL(string: picked.url) {
                store.openURL(url, inNewTab: false)
            }
            return
        }
        let query = omniboxText
        omniboxFocused = false
        selectedSuggestionIndex = nil
        store.navigateActiveTab(input: query)
    }

    private func barIconButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(disabled ? theme.palette.tertiaryText.opacity(0.45) : theme.palette.secondaryText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .hoverTooltip(help)
    }

    // MARK: Keychain AutoFill & Password Generator Popover

    private func autofillPopover(store: BrowserStore, tab: BrowserTabSession) -> some View {
        BrowserAutofillPopoverView(store: store, tab: tab, isPresented: $autofillPopoverOpen)
    }

    // MARK: WebExtensions Manager Popover

    private func extensionsManagerPopover(store: BrowserStore) -> some View {
        BrowserExtensionsPopoverView(store: store, windowProvider: { context.window()?.window })
    }

    // MARK: Downloads Popover

    private func downloadsPopover(downloads: WebDownloads) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") {
                    downloads.clearRecentDownloads()
                    if downloads.recentDownloads.isEmpty { downloadsPopoverOpen = false }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(downloads.recentDownloads) { item in
                        HStack(spacing: 8) {
                            Group {
                                switch item.state {
                                case .inProgress:
                                    ProgressView().controlSize(.small)
                                case .finished:
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                case .failed:
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                                }
                            }
                            .frame(width: 16)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.filename)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                if case .failed(let msg) = item.state {
                                    Text(msg)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if case .finished = item.state, let url = item.destinationURL {
                                Button("Show") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                                .controlSize(.mini)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: Knowledge Backlinks & Persistent Highlights Popover

    private func highlightSwiftUIColor(_ color: BrowserHighlightColor) -> Color {
        switch color {
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .pink: .pink
        case .purple: .purple
        }
    }

    private func knowledgeBacklinksPopover(store: BrowserStore, tab: BrowserTabSession) -> some View {
        let backlinks = store.backlinks(for: tab.urlString)
        let pageHighlights = store.highlights(for: tab.urlString)
        let boundSpace = store.boundSpaceSummary(for: tab)
        let clipFolder = BrowserSpaceRoutingLogic.clipFolder(for: boundSpace)

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.accent)
                    Text("Knowledge & Highlights")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button {
                        Task { await store.refreshKnowledgeIndex(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip("Refresh Knowledge backlinks")
                }

                if let boundSpace {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.palette.accent)
                        Text("Space: **\(boundSpace.name)** → `\(clipFolder)`")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.palette.accent.opacity(0.08)))
                }

                // Backlinks section
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("LINKED KNOWLEDGE NOTES")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if !backlinks.isEmpty {
                            Text("\(backlinks.count)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Clip Page") {
                            knowledgePopoverOpen = false
                            Task { await store.clipToKnowledge(tab: tab, includeSelectionOnlyIfPresent: true) }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }

                    if backlinks.isEmpty {
                        Text("No Knowledge notes reference this page or site yet.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(backlinks.prefix(8)) { item in
                            Button {
                                knowledgePopoverOpen = false
                                context.window()?.app.openVesperTab(path: "/knowledge/\(item.id)", nextTo: context.window()?.window)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: item.matchKind == .exactURL ? "doc.text.fill" : "globe")
                                        .font(.system(size: 11))
                                        .foregroundStyle(item.matchKind == .exactURL ? theme.palette.accent : .secondary)
                                        .frame(width: 14)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(theme.palette.text)
                                            .lineLimit(1)
                                        Text(item.path)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Text(item.matchKind.badgeLabel)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(item.matchKind == .exactURL ? theme.palette.accent : .secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(
                                            Capsule().fill((item.matchKind == .exactURL ? theme.palette.accent : Color.secondary).opacity(0.12))
                                        )
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(theme.palette.surface.opacity(0.75)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()

                // Persistent Web Highlights section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("PAGE HIGHLIGHTS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if !pageHighlights.isEmpty {
                            Text("\(pageHighlights.count)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if !tab.isPrivate {
                        HStack(spacing: 6) {
                            ForEach(BrowserHighlightColor.allCases) { c in
                                Button {
                                    highlightColor = c
                                } label: {
                                    Circle()
                                        .fill(highlightSwiftUIColor(c))
                                        .frame(width: 15, height: 15)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.primary, lineWidth: highlightColor == c ? 1.8 : 0)
                                                .padding(-2)
                                        )
                                }
                                .buttonStyle(.plain)
                                .hoverTooltip(c.label)
                            }
                            Spacer()
                            Button {
                                let noteText = highlightNote
                                highlightNote = ""
                                Task {
                                    await store.highlightSelection(
                                        in: tab,
                                        color: highlightColor,
                                        note: noteText.isEmpty ? nil : noteText
                                    )
                                }
                            } label: {
                                Label("Highlight (⌘⇧H)", systemImage: "highlighter")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        TextField("Optional note for highlight…", text: $highlightNote)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                            .onSubmit {
                                let noteText = highlightNote
                                highlightNote = ""
                                Task {
                                    await store.highlightSelection(
                                        in: tab,
                                        color: highlightColor,
                                        note: noteText.isEmpty ? nil : noteText
                                    )
                                }
                            }
                    } else {
                        Text("Highlights aren't saved on Private tabs.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if pageHighlights.isEmpty {
                        Text("Select text on the page and press ⌘⇧H to highlight & sync it to Knowledge.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pageHighlights) { h in
                            HStack(alignment: .top, spacing: 7) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(highlightSwiftUIColor(h.color))
                                    .frame(width: 3.5)
                                    .padding(.vertical, 2)

                                Button {
                                    tab.scrollToHighlight(id: h.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("“\(h.quote)”")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(theme.palette.text)
                                            .lineLimit(3)
                                            .multilineTextAlignment(.leading)
                                        if let note = h.note, !note.isEmpty {
                                            Text(note)
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .hoverTooltip("Scroll to highlight on page")

                                HStack(spacing: 4) {
                                    if let pageId = h.knowledgePageId {
                                        Button {
                                            knowledgePopoverOpen = false
                                            context.window()?.app.openVesperTab(path: "/knowledge/\(pageId)", nextTo: context.window()?.window)
                                        } label: {
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .hoverTooltip("Open synced Knowledge note")
                                    }
                                    Button {
                                        store.deleteHighlight(id: h.id, in: tab)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .hoverTooltip("Remove highlight")
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.palette.surface.opacity(0.75)))
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 340)
        .frame(maxHeight: 460)
    }

    // MARK: Share With Persona Pill & Popover

    private func sharePillButton(store: BrowserStore, tab: BrowserTabSession) -> some View {
        let isTabSharing = tab.activeShare != nil
        let isMultiSharing = store.multiTabShare != nil
        let isFollowing = store.isAutoFollowEnabled
        let isActiveShare = isTabSharing || isMultiSharing || (isFollowing && store.followShare != nil)
        let check = store.pageShareCheck(for: tab)
        let totalReads = (tab.activeShare?.reads.count ?? 0)
            + (store.multiTabShare?.reads.count ?? 0)
            + (store.followShare?.reads.count ?? 0)

        let pillTitle: String = if isMultiSharing {
            "Sharing \(store.multiTabShareCount)"
        } else if isFollowing {
            store.followPausedReason != nil ? "Follow · Paused" : "Following"
        } else if isTabSharing {
            "Sharing"
        } else {
            "Share"
        }

        let dotColor: Color = if isActiveShare {
            .orange
        } else if isFollowing {
            .yellow
        } else {
            check.ok ? Color.secondary.opacity(0.45) : Color.red.opacity(0.45)
        }

        return Button {
            sharePopoverOpen.toggle()
            if sharePopoverOpen {
                let boundSpace = store.boundSpaceSummary(for: tab)
                selectedShareTarget = BrowserSpaceRoutingLogic.defaultShareTarget(
                    space: boundSpace,
                    companionChatId: context.window()?.companionChatId,
                    personas: store.extensionConfig.personas
                )
                if multiTabSelection.isEmpty {
                    multiTabSelection = [tab.id]
                }
                Task { await store.refreshExtensionConfig() }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(pillTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isActiveShare ? Color.orange : theme.palette.text)
                if totalReads > 0 {
                    Text("\(totalReads)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(Color.orange)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(isActiveShare ? Color.orange.opacity(0.14) : theme.palette.surface)
                    .overlay(Capsule().stroke(isActiveShare ? Color.orange.opacity(0.45) : theme.palette.border.opacity(0.55), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .disabled(!tab.hasLoadedPage && !isActiveShare)
        .hoverTooltip(isActiveShare ? "Manage live tab share or Auto-Follow with persona" : "Share tab(s), enable Auto-Follow, or ask a persona")
        .popover(isPresented: $sharePopoverOpen, arrowEdge: .bottom) {
            sharePopover(store: store, tab: tab)
        }
    }

    private func sharePopover(store: BrowserStore, tab: BrowserTabSession) -> some View {
        let check = store.pageShareCheck(for: tab)
        let actions = BrowserPageGuard.siteActions(url: tab.urlString, personas: store.extensionConfig.personas)
        let companionChatId = context.window()?.companionChatId
        let boundSpace = store.boundSpaceSummary(for: tab)
        let shareableTabs = store.orderedTabs.filter { !$0.isPrivate && $0.hasLoadedPage && store.pageShareCheck(for: $0).ok }

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Companion Auto-Follow Active Tab toggle
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(isOn: Binding(
                        get: { store.isAutoFollowEnabled },
                        set: { store.setAutoFollowCompanionTab($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto-Follow Active Tab")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Keeps Companion Chat synced as you switch tabs. Skips Private & never-share sites.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    if store.isAutoFollowEnabled {
                        if let paused = store.followPausedReason {
                            Label(paused, systemImage: "pause.circle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.orange)
                        } else if let follow = store.followShare {
                            HStack(spacing: 6) {
                                Circle().fill(Color.orange).frame(width: 6, height: 6)
                                Text("Following in “\(follow.chatTitle.isEmpty ? "Companion" : follow.chatTitle)”")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Button("Open") {
                                    context.window()?.openCompanionChat(follow.chatId)
                                    sharePopoverOpen = false
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 10.5))
                            }
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.palette.surface.opacity(0.75)))

                // Active Multi-Tab Share status card
                if let multi = store.multiTabShare {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(Color.orange).frame(width: 8, height: 8)
                            Text("Sharing \(store.multiTabShareCount) tabs")
                                .font(.system(size: 12.5, weight: .semibold))
                            Spacer()
                            Button("Open Companion") {
                                context.window()?.openCompanionChat(multi.chatId)
                                sharePopoverOpen = false
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }
                        Text("\(multi.title) · \(multi.reads.count) read\(multi.reads.count == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack {
                            Spacer()
                            Button("Stop Multi-Tab Share") {
                                Task { await store.stopMultiTabShare(reason: "person") }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
                }

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
                        HStack {
                            Text("Let a persona see this tab")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if let boundSpace {
                                Label(boundSpace.name, systemImage: "square.stack.3d.up.fill")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(theme.palette.accent)
                                    .lineLimit(1)
                            }
                        }

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

                // Multi-Tab / Tab Group Sharing section
                if shareableTabs.count >= 2 {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.14)) {
                                multiTabPickerExpanded.toggle()
                                if multiTabPickerExpanded {
                                    let currentGroupIDs = tab.groupId.map { gid in
                                        Set(shareableTabs.filter { $0.groupId == gid }.map(\.id))
                                    }
                                    if let currentGroupIDs, currentGroupIDs.count >= 2 {
                                        multiTabSelection = currentGroupIDs
                                    } else {
                                        multiTabSelection = Set(shareableTabs.prefix(4).map(\.id))
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: multiTabPickerExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "square.on.square")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.palette.accent)
                                Text("Share Multiple Tabs / Group")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.palette.text)
                                Spacer()
                                Text("\(shareableTabs.count)")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if multiTabPickerExpanded {
                            HStack(spacing: 6) {
                                if let gid = tab.groupId,
                                   let group = store.tabGroups.first(where: { $0.id == gid })
                                {
                                    Button("Group: \(group.name)") {
                                        multiTabSelection = Set(shareableTabs.filter { $0.groupId == gid }.map(\.id))
                                    }
                                    .controlSize(.mini)
                                }
                                Button("All (\(shareableTabs.count))") {
                                    multiTabSelection = Set(shareableTabs.map(\.id))
                                }
                                .controlSize(.mini)
                                Button("None") {
                                    multiTabSelection = []
                                }
                                .controlSize(.mini)
                                Spacer()
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(shareableTabs.prefix(12)) { candidate in
                                    let isSelected = multiTabSelection.contains(candidate.id)
                                    Button {
                                        if isSelected {
                                            multiTabSelection.remove(candidate.id)
                                        } else {
                                            multiTabSelection.insert(candidate.id)
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(isSelected ? theme.palette.accent : .secondary)
                                            Text(candidate.displayTitle)
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(theme.palette.text)
                                                .lineLimit(1)
                                            Spacer(minLength: 4)
                                            Text(candidate.displayHost)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .padding(.vertical, 2)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            let chosen = shareableTabs.filter { multiTabSelection.contains($0.id) }
                            Button {
                                isSubmittingAction = true
                                sharePopoverOpen = false
                                Task {
                                    defer { isSubmittingAction = false }
                                    let (chatId, personaId) = resolveShareTarget(
                                        selection: selectedShareTarget,
                                        companionChatId: companionChatId,
                                        personas: store.extensionConfig.personas
                                    )
                                    let sharedGroupName: String? = {
                                        let gids = Set(chosen.compactMap(\.groupId))
                                        if gids.count == 1, let gid = gids.first, chosen.allSatisfy({ $0.groupId == gid }) {
                                            return store.tabGroups.first(where: { $0.id == gid })?.name
                                        }
                                        return nil
                                    }()
                                    await store.shareMultipleTabs(
                                        chosen,
                                        groupName: sharedGroupName,
                                        chatId: chatId,
                                        personaId: personaId,
                                        includeScreenshot: shareIncludeScreenshot,
                                        openInCompanion: true
                                    )
                                }
                            } label: {
                                Text("Share \(chosen.count) Selected Tab\(chosen.count == 1 ? "" : "s")")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(chosen.isEmpty || isSubmittingAction)
                        }
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
        .frame(width: 330)
        .frame(maxHeight: 540)
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
        let spacePersona = store.boundSpace(for: tab)?.personaId
        let def = spacePersona ?? (store.extensionConfig.personas.first(where: \.isDefault) ?? store.extensionConfig.personas.first)?.id
        Task {
            await store.askAboutPage(tab: tab, prompt: prompt, personaId: def, openInCompanion: true)
        }
    }

    // MARK: Omnibox Autocomplete Overlay

    private func currentSuggestions(store: BrowserStore) -> [BrowserOmniboxSuggestion] {
        let savedItems = (context.store.entry(Self.savedLinksRequest).data?.items ?? []).compactMap { item -> (id: String, title: String, url: String, site: String?)? in
            guard let url = item.url, !url.isEmpty else { return nil }
            return (item.id, item.title, url, item.site)
        }
        return BrowserTabListLogic.suggestions(
            query: omniboxText,
            openTabs: store.tabs.map(\.record),
            bookmarks: store.bookmarks,
            savedLinks: savedItems,
            history: store.history,
            limit: 8
        )
    }

    @ViewBuilder
    private func omniboxSuggestionsOverlay(store: BrowserStore) -> some View {
        let suggestions = currentSuggestions(store: store)
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, s in
                    let isSelected = selectedSuggestionIndex == idx
                    Button {
                        omniboxFocused = false
                        selectedSuggestionIndex = nil
                        if let tabId = s.tabId {
                            store.selectTab(tabId)
                        } else if let url = URL(string: s.url) {
                            store.openURL(url, inNewTab: false)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: suggestionSymbol(s.kind))
                                .font(.system(size: 11))
                                .foregroundStyle(isSelected ? theme.palette.accent : theme.palette.secondaryText)
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
                        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? theme.palette.selected : Color.clear))
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
        let profile = store.currentRuntime
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: tab.isPrivate ? "eye.slash" : profile.icon)
                            .font(.system(size: 22))
                            .foregroundStyle(tab.isPrivate ? Color.purple : profile.color.swiftUIColor)
                        Text(tab.isPrivate ? "Private Tab" : "Vesper Browser · \(profile.name)")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(theme.palette.text)
                    }
                    Text(
                        tab.isPrivate
                            ? "Cookies, cache, history, and passwords stay out of disk. Private tabs are never shared with personas."
                            : "⌘L address bar · ⌘⌃1–9 web tabs · ⌘⌃\\ split view · ⌘⇧A Keychain AutoFill · ⌘⌃E extensions."
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
                                    favicon: BrowserFaviconCache.shared.cachedIcon(for: bm.url),
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
                                        favicon: BrowserFaviconCache.shared.cachedIcon(for: raw),
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

    private func startPageCard(title: String, subtitle: String, favicon: NSImage?, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 15, height: 15)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.accent)
                }
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
        syncFocusModeToShell(store.isFocusMode)
        syncActiveTabChrome(store: store)
    }

    private func syncFocusModeToShell(_ focus: Bool) {
        guard let state = context.window()?.state else { return }
        state.sidebarHidden = focus
        state.railHidden = focus
    }

    private func handleIncomingQueryURL() {
        guard let store, let raw = context.match.query["url"], let url = URL(string: raw), BrowserURLResolver.isWebURL(url) else {
            return
        }
        let inNewTab = context.match.query["newTab"] != "0"
        store.openURL(url, inNewTab: inNewTab, reuseExisting: true)
        context.navigate("/browser", replace: true)
    }

    private func syncActiveTabChrome(store: BrowserStore) {
        let tab = store.activeTab
        context.find.searcher = tab?.webView
        context.chrome = NativeChrome(
            title: tab?.displayTitle ?? "Browser",
            subtitle: tab?.displayHost.isEmpty == false ? tab?.displayHost : store.currentRuntime.name,
            toolbarItems: [],
            inspector: nil
        )
        if !omniboxFocused {
            syncOmniboxDisplay(store: store)
        }
    }

    private func siteSecurityButton(store: BrowserStore, tab: BrowserTabSession) -> some View {
        let sec = tab.connectionSecurity
        let idn = tab.hostSecurityDisplay
        let isLockdown = store.isLockdownActive(for: tab.urlString)
        return Button {
            tab.refreshCertificateSummary()
            siteSecurityPopoverOpen.toggle()
        } label: {
            HStack(spacing: 3) {
                if idn.isSuspiciousIDN {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("IDN")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.orange)
                } else {
                    switch sec {
                    case .secure:
                        Image(systemName: isLockdown ? "lock.shield.fill" : "lock.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(isLockdown ? Color.orange : theme.palette.tertiaryText)
                    case .mixedContent:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    case .insecureHTTP:
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.red)
                        Text("Not Secure")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.red)
                    case .tlsError:
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                        Text("Cert Error")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.red)
                    case .localHTTP, .internalPage:
                        Image(systemName: "info.circle")
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, (sec.isWarning || idn.isSuspiciousIDN) ? 5 : 2)
            .padding(.vertical, (sec.isWarning || idn.isSuspiciousIDN) ? 1.5 : 0)
            .background(
                Group {
                    if sec == .insecureHTTP || (sec.isWarning && !idn.isSuspiciousIDN && sec != .mixedContent) {
                        Capsule().fill(Color.red.opacity(0.12))
                    } else if sec == .mixedContent || idn.isSuspiciousIDN {
                        Capsule().fill(Color.orange.opacity(0.14))
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .hoverTooltip("Connection Security, Certificate & Site Permissions")
        .popover(isPresented: $siteSecurityPopoverOpen, arrowEdge: .bottom) {
            BrowserSiteSecurityPopover(store: store, tab: tab, isPresented: $siteSecurityPopoverOpen)
        }
    }

    private func syncOmniboxDisplay(store: BrowserStore) {
        guard let tab = store.activeTab, tab.hasLoadedPage else {
            omniboxText = ""
            return
        }
        let idn = tab.hostSecurityDisplay
        if idn.isSuspiciousIDN, !idn.displayHost.isEmpty {
            omniboxText = idn.displayHost
        } else {
            omniboxText = BrowserURLResolver.displayAddress(for: tab.urlString)
        }
    }

    private func focusOmnibox(store: BrowserStore) {
        omniboxPeekVisible = true
        omniboxText = store.activeTab?.urlString ?? ""
        context.window()?.window?.makeFirstResponder(nil)
        omniboxFocused = true
    }
}

// MARK: - Keychain AutoFill & Vault Popover

private struct BrowserAutofillPopoverView: View {
    let store: BrowserStore
    let tab: BrowserTabSession
    @Binding var isPresented: Bool

    @State private var search = ""
    @State private var isAdding = false
    @State private var newUsername = ""
    @State private var newPassword = ""
    @State private var pwLength: Double = 20
    @State private var includeSymbols = true

    var body: some View {
        let host = BrowserPageGuard.normalizeHost(tab.urlString) ?? ""
        let secureOrigin = BrowserAutofillLogic.canAutofill(
            urlString: tab.urlString,
            hasOnlySecureContent: tab.hasOnlySecureContent
        )
        let matching = store.autofill.matchingCredentials(for: tab.urlString)
        let allCreds = store.autofill.credentials.filter {
            let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { return true }
            return $0.host.lowercased().contains(needle) || $0.username.lowercased().contains(needle)
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Keychain AutoFill (\(store.currentRuntime.name))", systemImage: "key.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) { isAdding.toggle() }
                    } label: {
                        Image(systemName: isAdding ? "xmark" : "plus")
                    }
                    .controlSize(.small)
                    .hoverTooltip("Add login for this site")
                }

                if !secureOrigin {
                    Text("AutoFill is restricted to secure HTTPS (no mixed content) and localhost pages.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if !matching.isEmpty {
                    Text("For \(host)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(matching) { cred in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cred.username)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(cred.host)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Fill") {
                                isPresented = false
                                Task { await store.fillCredential(cred, into: tab) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.08)))
                    }
                } else {
                    Text("No saved logins for \(host.isEmpty ? "this page" : host).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if isAdding, !host.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add Keychain login for \(host)")
                            .font(.system(size: 11, weight: .semibold))
                        TextField("Username or email", text: $newUsername)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        SecureField("Password", text: $newPassword)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        HStack {
                            Button("Generate") {
                                newPassword = BrowserAutofillLogic.generateStrongPassword(
                                    length: Int(pwLength),
                                    includeSymbols: includeSymbols
                                )
                            }
                            .controlSize(.small)
                            Spacer()
                            Button("Save to Keychain") {
                                if store.autofill.saveCredential(host: host, username: newUsername, password: newPassword) {
                                    newUsername = ""
                                    newPassword = ""
                                    isAdding = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newPassword.isEmpty)
                        }
                    }
                }

                Divider()

                // Strong Password Generator
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Strong Password Generator")
                            .font(.system(size: 11.5, weight: .semibold))
                        Spacer()
                        Text("\(Int(pwLength)) chars")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Slider(value: $pwLength, in: 12...36, step: 2)
                        Toggle("Symbols", isOn: $includeSymbols)
                            .font(.system(size: 11))
                    }
                    Button {
                        isPresented = false
                        Task {
                            await store.generateAndFillPassword(
                                for: tab,
                                length: Int(pwLength),
                                includeSymbols: includeSymbols
                            )
                        }
                    } label: {
                        Label("Generate, Fill & Copy Password", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                }

                if !store.autofill.credentials.isEmpty {
                    Divider()
                    Text("Saved Logins (\(store.autofill.credentials.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if store.autofill.credentials.count > 4 {
                        TextField("Filter saved logins…", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                    }
                    ForEach(allCreds.prefix(12)) { cred in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cred.host)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                Text(cred.username)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                Task { await store.copyCredentialPassword(cred) }
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10.5))
                            }
                            .buttonStyle(.plain)
                            .hoverTooltip("Copy password")

                            Button(role: .destructive) {
                                _ = store.autofill.deleteCredential(id: cred.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .hoverTooltip("Remove from Keychain")
                        }
                        .padding(.vertical, 2)
                    }
                }

                Divider()

                Toggle("Require Touch ID to fill or copy passwords", isOn: Binding(
                    get: { store.securityConfig.requireTouchIDForAutofill },
                    set: {
                        store.securityConfig.requireTouchIDForAutofill = $0
                        store.scheduleSave()
                    }
                ))
                .font(.system(size: 11))

                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.commaSeparatedText, .plainText]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        store.importApplePasswordsCSV(from: url)
                    }
                } label: {
                    Label("Import Apple Passwords CSV…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
            .padding(14)
        }
        .frame(width: 320)
        .frame(maxHeight: 460)
    }
}

// MARK: - WebExtensions Manager Popover

private struct BrowserExtensionsPopoverView: View {
    let store: BrowserStore
    let windowProvider: () -> NSWindow?

    @State private var installError: String?

    var body: some View {
        let host = store.extensionHost
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("WebExtensions (\(store.currentRuntime.name))", systemImage: "puzzlepiece.extension")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }

                Text("Load MV3 / MV2 WebExtensions via native WebKit (`WKWebExtensionController`). Extensions are isolated per profile.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        pickAndInstall(allowDirectories: true, copyManaged: false)
                    } label: {
                        Label("Load Unpacked…", systemImage: "folder")
                    }
                    .controlSize(.small)

                    Button {
                        pickAndInstall(allowDirectories: false, copyManaged: true)
                    } label: {
                        Label("Install .zip / .appex…", systemImage: "plus.app")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if let err = installError ?? host.lastError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                Divider()

                if host.toolbarItems.isEmpty {
                    Text("No extensions installed in this profile yet.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(host.toolbarItems) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                if let icon = item.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 22, height: 22)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                } else {
                                    Image(systemName: "puzzlepiece.extension.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22, height: 22)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(item.displayName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        if !item.version.isEmpty {
                                            Text("v\(item.version)")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if !item.description.isEmpty {
                                        Text(item.description)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { item.isEnabled },
                                    set: { next in
                                        Task { await host.setEnabled(next, for: item.id) }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                            }

                            HStack(spacing: 8) {
                                if item.isLoaded {
                                    Button("Run Action") {
                                        host.performAction(for: item.id)
                                    }
                                    .controlSize(.mini)
                                }
                                if item.hasOptionsPage {
                                    Button("Options") {
                                        host.openOptionsPage(for: item.id)
                                    }
                                    .controlSize(.mini)
                                }
                                if item.isLoaded {
                                    Button(item.grantedHosts.isEmpty ? "Grant Site Access" : "Revoke Site Access") {
                                        if item.grantedHosts.isEmpty {
                                            host.grantAllRequestedAccess(for: item.id)
                                        } else {
                                            host.revokeAllHostAccess(for: item.id)
                                        }
                                    }
                                    .controlSize(.mini)
                                }
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    host.removeExtension(id: item.id)
                                }
                                .controlSize(.mini)
                            }

                            Toggle("Allow in Private Tabs", isOn: Binding(
                                get: { item.allowInPrivate },
                                set: { host.setAllowInPrivate($0, for: item.id) }
                            ))
                            .font(.system(size: 10.5))

                            if !item.errors.isEmpty {
                                Text(item.errors.joined(separator: "\n"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.red)
                                    .lineLimit(3)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 360)
        .frame(maxHeight: 480)
    }

    private func pickAndInstall(allowDirectories: Bool, copyManaged: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = allowDirectories
        panel.canChooseFiles = !allowDirectories
        panel.allowsMultipleSelection = false
        panel.prompt = allowDirectories ? "Load Extension" : "Install Extension"
        if !allowDirectories {
            var types: [UTType] = [.zip]
            if let appex = UTType(filenameExtension: "appex") { types.append(appex) }
            panel.allowedContentTypes = types
        }

        Task { @MainActor in
            let response: NSApplication.ModalResponse
            if let window = windowProvider() {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK, let url = panel.url else { return }
            let result = await store.extensionHost.installExtension(from: url, copyIntoManagedStorage: copyManaged)
            switch result {
            case .success(let rec):
                installError = nil
                store.showToast("Installed extension \(rec.displayName)", tone: .success)
            case .failure(let err):
                installError = err.localizedDescription
            }
        }
    }
}

// MARK: - Site Security, Certificate Inspector & Per-Site Permissions Popover

private struct BrowserSiteSecurityPopover: View {
    let store: BrowserStore
    let tab: BrowserTabSession
    @Binding var isPresented: Bool

    var body: some View {
        let host = BrowserPageGuard.normalizeHost(tab.urlString) ?? ""
        let sec = tab.connectionSecurity
        let idn = tab.hostSecurityDisplay

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: sec.isWarning || idn.isSuspiciousIDN ? "exclamationmark.triangle.fill" : "lock.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(sec.isWarning || idn.isSuspiciousIDN ? .orange : .green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sec.label)
                            .font(.system(size: 12.5, weight: .semibold))
                        if !host.isEmpty {
                            Text(idn.isSuspiciousIDN ? idn.displayHost : host)
                                .font(.system(size: 10.5).monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }

                if let warning = idn.warningReason {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
                }

                if let cert = tab.certificateSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TLS Certificate")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Issued to: \(cert.subject)")
                            .font(.system(size: 11))
                            .lineLimit(1)
                        if !cert.issuer.isEmpty {
                            Text("Issued by: \(cert.issuer)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let until = cert.validUntil {
                            Text("Expires \(until.formatted(date: .abbreviated, time: .omitted)) · \(cert.chainCount) cert\(cert.chainCount == 1 ? "" : "s") in chain")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Button("Show System Certificate…") {
                            isPresented = false
                            tab.showSystemCertificatePanel()
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
                }

                if !host.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Site Controls (\(host))")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Toggle("Lockdown Mode for this site", isOn: Binding(
                            get: { store.isLockdownActive(for: tab.urlString) },
                            set: { _ in store.toggleLockdown(forHost: host) }
                        ))
                        .font(.system(size: 11.5))

                        Toggle("Allow JavaScript", isOn: Binding(
                            get: { store.isJavaScriptAllowed(for: tab.urlString) },
                            set: { _ in store.toggleJavaScript(forHost: host) }
                        ))
                        .font(.system(size: 11.5))
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Permissions")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)

                        ForEach(BrowserPermissionKind.allCases) { kind in
                            HStack {
                                Label(kind.label, systemImage: kind.icon)
                                    .font(.system(size: 11.5))
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { store.sitePermission(forHost: host, kind: kind) },
                                    set: { store.setSitePermission(host: host, kind: kind, setting: $0) }
                                )) {
                                    ForEach(BrowserPermissionSetting.allCases) { opt in
                                        Text(opt.label).tag(opt)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 82)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 316)
        .frame(maxHeight: 430)
    }
}

// MARK: - Wipr / uBlock-Grade Shield, Filter Lists & Browser Controls Popover

private struct BrowserShieldPopover: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Protection"
        case security = "Security"
        case lists = "Lists"
        case custom = "Custom"
        var id: String { rawValue }
    }

    let store: BrowserStore
    let tab: BrowserTabSession?
    @Binding var isPresented: Bool

    @State private var selectedTab: Tab = .overview
    @State private var customListName = ""
    @State private var customListURL = ""
    @State private var customListCategory: BrowserAdBlockCategory = .ads
    @State private var addListError: String?
    @State private var customRulesDraft = ""
    @State private var didSeedDraft = false
    @State private var proxyMode: BrowserProxyMode = .none
    @State private var proxyHost = ""
    @State private var proxyPort = "1080"
    @State private var proxyApplyPrivate = true

    private var currentHost: String? {
        tab.flatMap { BrowserPageGuard.normalizeHost($0.urlString) }
    }

    private var isProtectedOnCurrentPage: Bool {
        store.isAdBlockActive(for: tab?.urlString ?? "")
    }

    var body: some View {
        let engine = store.adBlockEngine
        VStack(alignment: .leading, spacing: 10) {
            // Header + Live Engine Summary
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isProtectedOnCurrentPage ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isProtectedOnCurrentPage ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(statusSubtitle(engine: engine))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if engine.isCompiling || engine.isUpdating {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            Divider()

            switch selectedTab {
            case .overview:
                overviewSection(engine: engine)
            case .security:
                securitySection()
            case .lists:
                filterListsSection(engine: engine)
            case .custom:
                customRulesSection()
            }
        }
        .padding(14)
        .frame(width: 356)
        .onAppear {
            if !didSeedDraft {
                customRulesDraft = store.adBlockConfig.customRules
                let p = store.currentRuntime.proxyConfig
                proxyMode = p.mode
                proxyHost = p.host
                proxyPort = String(p.port)
                proxyApplyPrivate = p.applyToPrivateTabs
                didSeedDraft = true
            }
        }
    }

    @ViewBuilder
    private func securitySection() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text("WebKit Hardening")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("Known-host HTTPS upgrades and Fraudulent Website Warnings are always on.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Toggle("Strict HTTPS-Only Mode", isOn: Binding(
                    get: { store.securityConfig.httpsOnlyMode },
                    set: {
                        store.securityConfig.httpsOnlyMode = $0
                        store.scheduleSave()
                    }
                ))
                .font(.system(size: 11.5))

                Toggle("Lockdown Mode (Global Default)", isOn: Binding(
                    get: { store.securityConfig.lockdownModeEnabled },
                    set: {
                        store.securityConfig.lockdownModeEnabled = $0
                        store.scheduleSave()
                        tab?.reload()
                    }
                ))
                .font(.system(size: 11.5))

                Toggle("Strip URL Tracking Parameters", isOn: Binding(
                    get: { store.securityConfig.stripTrackingParameters },
                    set: {
                        store.securityConfig.stripTrackingParameters = $0
                        store.scheduleSave()
                    }
                ))
                .font(.system(size: 11.5))

                Toggle("Confirm Downloads & Warn on Installers", isOn: Binding(
                    get: { store.securityConfig.confirmDownloads },
                    set: {
                        store.securityConfig.confirmDownloads = $0
                        store.scheduleSave()
                    }
                ))
                .font(.system(size: 11.5))

                Toggle("Block Top-Level data: Pages", isOn: Binding(
                    get: { store.securityConfig.blockTopLevelDataNavigations },
                    set: {
                        store.securityConfig.blockTopLevelDataNavigations = $0
                        store.scheduleSave()
                    }
                ))
                .font(.system(size: 11.5))

                Toggle("Require Touch ID for Keychain AutoFill", isOn: Binding(
                    get: { store.securityConfig.requireTouchIDForAutofill },
                    set: {
                        store.securityConfig.requireTouchIDForAutofill = $0
                        store.scheduleSave()
                    }
                ))
                .font(.system(size: 11.5))

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Profile Proxy (\(store.currentRuntime.name))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Picker("Proxy Type", selection: $proxyMode) {
                        ForEach(BrowserProxyMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .controlSize(.small)

                    if proxyMode != .none {
                        HStack(spacing: 6) {
                            TextField("Host (e.g. 127.0.0.1)", text: $proxyHost)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            TextField("Port", text: $proxyPort)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .frame(width: 68)
                        }
                        Toggle("Also route Private Tabs through this proxy", isOn: $proxyApplyPrivate)
                            .font(.system(size: 10.5))
                    }

                    HStack {
                        Spacer()
                        Button("Apply Proxy") {
                            let port = Int(proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1080
                            let cfg = BrowserProxyConfig(
                                mode: proxyMode,
                                host: proxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
                                port: min(65535, max(1, port)),
                                applyToPrivateTabs: proxyApplyPrivate
                            )
                            store.updateProxyConfig(cfg)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxHeight: 420)
    }

    private var statusTitle: String {
        if !store.adBlockEnabled { return "Ad-Blocking Off" }
        if let host = currentHost {
            return isProtectedOnCurrentPage ? "Shields Up · \(host)" : "Shields Paused · \(host)"
        }
        return "Shields Up"
    }

    private func statusSubtitle(engine: BrowserAdBlockEngine) -> String {
        if engine.isUpdating { return "Updating upstream filter lists…" }
        if engine.isCompiling { return "Compiling WebKit rule lists…" }
        if !store.adBlockEnabled { return "Turn on to block ads, trackers, and annoyances" }
        let rules = engine.stats.totalActiveRules
        let hits = tab?.adBlockInterventionsCount ?? 0
        if hits > 0 {
            return "\(rules) active rules (\(engine.compiledChunkCount) lists) · \(hits) scriptlet/cosmetic hits"
        }
        return "\(rules) active rules across \(engine.compiledChunkCount) WebKit lists"
    }

    // MARK: Overview Tab

    @ViewBuilder
    private func overviewSection(engine: BrowserAdBlockEngine) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Toggle("Block Ads, Trackers & Annoyances", isOn: Binding(
                    get: { store.adBlockEnabled },
                    set: { store.setAdBlockEnabled($0) }
                ))
                .font(.system(size: 12, weight: .medium))

                if let host = currentHost, store.adBlockEnabled {
                    Toggle("Protect \(host)", isOn: Binding(
                        get: { isProtectedOnCurrentPage },
                        set: { _ in store.toggleAdBlock(forHost: host) }
                    ))
                    .font(.system(size: 12))
                }

                if store.adBlockEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Protection Layers")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)

                        ForEach(BrowserAdBlockCategory.allCases) { category in
                            Toggle(isOn: Binding(
                                get: { store.adBlockConfig.isCategoryEnabled(category) },
                                set: { store.setAdBlockCategory(category, enabled: $0) }
                            )) {
                                HStack(spacing: 6) {
                                    Image(systemName: category.icon)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 14)
                                    VStack(alignment: .leading, spacing: 0.5) {
                                        Text(category.label)
                                            .font(.system(size: 11.5))
                                        Text(category.summary)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }

                        Toggle(isOn: Binding(
                            get: { store.adBlockConfig.youtubeAdShieldEnabled },
                            set: { store.setYouTubeAdShieldEnabled($0) }
                        )) {
                            HStack(spacing: 6) {
                                Image(systemName: "play.rectangle.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 0.5) {
                                    Text("YouTube Ad Shield")
                                        .font(.system(size: 11.5))
                                    Text("Prunes playerAds JSON, dismisses enforcement & skips residual ads")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

                    if let err = engine.lastError {
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }

                Divider()

                Toggle("Offer Keychain Password AutoFill", isOn: Binding(
                    get: { store.autofillEnabled },
                    set: {
                        store.autofillEnabled = $0
                        store.scheduleSave()
                    }
                ))
                .font(.system(size: 12))

                Toggle("Open Vesper links in Browser", isOn: Binding(
                    get: { store.openExternalLinksInBrowser },
                    set: {
                        store.openExternalLinksInBrowser = $0
                        store.scheduleSave()
                    }
                ))
                .font(.system(size: 12))
                Text("Hold ⌥ while clicking any link to open it in Safari.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Display & Compact Layout")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Default page zoom")
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { store.layoutConfig.defaultZoom },
                            set: { store.setDefaultZoom($0) }
                        )) {
                            ForEach(BrowserLayoutConfig.presetZooms, id: \.self) { level in
                                Text("\(Int((level * 100).rounded()))%").tag(level)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 90)
                    }

                    Toggle("Auto-hide address bar", isOn: Binding(
                        get: { store.layoutConfig.autoHideOmnibox },
                        set: { store.setAutoHideOmnibox($0) }
                    ))
                    .font(.system(size: 12))

                    Toggle("Hover-peek sidebar when collapsed", isOn: Binding(
                        get: { store.layoutConfig.hoverPeekSidebar },
                        set: { store.setHoverPeekSidebar($0) }
                    ))
                    .font(.system(size: 12))

                    Toggle("Focus Mode (⌘⇧F)", isOn: Binding(
                        get: { store.isFocusMode },
                        set: { if store.isFocusMode != $0 { store.toggleFocusMode() } }
                    ))
                    .font(.system(size: 12))
                }

                Divider()

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
                    Button("Clear \(store.currentRuntime.name) Cookies & Cache", role: .destructive) {
                        isPresented = false
                        Task { await store.clearBrowsingData() }
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
        .frame(maxHeight: 420)
    }

    // MARK: Filter Lists Tab

    @ViewBuilder
    private func filterListsSection(engine: BrowserAdBlockEngine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Auto-update daily", isOn: Binding(
                    get: { store.adBlockConfig.autoUpdateEnabled },
                    set: { store.setAdBlockAutoUpdateEnabled($0) }
                ))
                .font(.system(size: 11.5))

                Spacer()

                Button {
                    Task { await store.refreshAdBlockLists(silent: false) }
                } label: {
                    Label(engine.isUpdating ? "Updating…" : "Update Lists", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .disabled(engine.isUpdating)
            }

            if let updated = store.adBlockConfig.lastUpdatedAt {
                Text("Last upstream refresh \(updated.formatted(.relative(presentation: .named))) · Bundled starter lists always active.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("Using bundled offline starter lists. Click Update Lists to pull full EasyList, EasyPrivacy, Fanboy & uBlock lists.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.adBlockConfig.subscriptions) { sub in
                        HStack(alignment: .top, spacing: 6) {
                            Toggle("", isOn: Binding(
                                get: { sub.isEnabled },
                                set: { store.setFilterListEnabled(id: sub.id, enabled: $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 1.5) {
                                HStack(spacing: 5) {
                                    Text(sub.name)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)
                                    Text(sub.category.rawValue)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 0.5)
                                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                                }
                                if let err = sub.lastError, !err.isEmpty {
                                    Text(err)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                } else if sub.ruleCount > 0 {
                                    Text("\(sub.ruleCount.formatted()) lines cached")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(sub.url)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }

                            Spacer(minLength: 4)

                            if !sub.isBuiltIn {
                                Button(role: .destructive) {
                                    store.removeCustomFilterList(id: sub.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10.5))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
                    }
                }
            }
            .frame(maxHeight: 215)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Add Custom Filter List (ABP / uBO / Hosts)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("Name (optional)", text: $customListName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Picker("", selection: $customListCategory) {
                        ForEach(BrowserAdBlockCategory.allCases) { cat in
                            Text(cat.label).tag(cat)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 118)
                    .controlSize(.small)
                }
                HStack(spacing: 6) {
                    TextField("https://example.com/filters.txt", text: $customListURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button("Add") {
                        let err = store.addCustomFilterList(
                            name: customListName,
                            urlString: customListURL,
                            category: customListCategory
                        )
                        addListError = err
                        if err == nil {
                            customListName = ""
                            customListURL = ""
                        }
                    }
                    .controlSize(.small)
                    .disabled(customListURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let addListError {
                    Text(addListError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Custom Rules Tab

    @ViewBuilder
    private func customRulesSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Supports ABP/uBO network rules, CSS hiding (`##.ad`), extended CSS (`:has-text()`, `:upward()`, `:style()`), and scriptlets (`##+js(...)`).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextEditor(text: $customRulesDraft)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 190)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                )

            HStack {
                Button("Clear", role: .destructive) {
                    customRulesDraft = ""
                    store.updateCustomAdBlockRules("")
                }
                .controlSize(.small)
                .disabled(customRulesDraft.isEmpty && store.adBlockConfig.customRules.isEmpty)

                Spacer()

                Button("Apply Rules") {
                    store.updateCustomAdBlockRules(customRulesDraft)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(customRulesDraft == store.adBlockConfig.customRules)
            }
        }
    }
}

// MARK: - Auto Dark Mode Popover (Noir / Dark Reader Style)

private struct BrowserDarkModePopover: View {
    let store: BrowserStore
    let tab: BrowserTabSession

    private var currentHost: String? {
        BrowserPageGuard.normalizeHost(tab.urlString)
    }

    private var siteOverride: BrowserDarkModeSiteOverride {
        store.darkModeSiteOverride(for: tab.urlString)
    }

    private var statusBadge: (label: String, color: Color) {
        switch tab.darkModeStatus {
        case .applied:
            return ("Active", .accentColor)
        case .skippedNative:
            return ("Native Dark", .green)
        case .inactive:
            if siteOverride == .off {
                return ("Off for Site", .secondary)
            }
            return ("Off", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Header + Live Page Status
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: tab.darkModeStatus == .applied ? "moon.stars.fill" : "moon.stars")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tab.darkModeStatus == .applied ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto Dark Mode")
                        .font(.system(size: 13, weight: .semibold))
                    Text(currentHost ?? "Current page")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(statusBadge.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusBadge.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusBadge.color.opacity(0.14)))
            }

            if let host = currentHost {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This Site")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Picker("", selection: Binding(
                        get: { siteOverride },
                        set: { store.setDarkModeSiteOverride($0, forHost: host) }
                    )) {
                        ForEach(BrowserDarkModeSiteOverride.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)

                    if tab.darkModeStatus == .skippedNative && siteOverride == .inherit {
                        Text("Skipped because this site already renders in dark mode. Choose Force Dark to override.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
            }

            // Global Mode
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Global Mode")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(store.darkModeConfig.mode.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Picker("", selection: Binding(
                    get: { store.darkModeConfig.mode },
                    set: { store.setDarkModeMode($0) }
                )) {
                    ForEach(BrowserDarkModeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            // Theme Swatches
            VStack(alignment: .leading, spacing: 5) {
                Text("Theme")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(BrowserDarkModeTheme.allCases) { item in
                        let selected = store.darkModeConfig.theme == item
                        Button {
                            store.setDarkModeTheme(item)
                        } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(hex: item.backgroundHex) ?? .black)
                                    .frame(height: 22)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(
                                                selected ? Color.accentColor : (Color(hex: item.swatchBorderHex) ?? .gray),
                                                lineWidth: selected ? 1.8 : 1
                                            )
                                    )
                                Text(item.label)
                                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // Smart Options
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Respect Native Dark Mode", isOn: Binding(
                    get: { store.darkModeConfig.respectNativeDarkMode },
                    set: { store.setDarkModeRespectNative($0) }
                ))
                .font(.system(size: 11.5))

                Toggle("Dim Images & Media", isOn: Binding(
                    get: { store.darkModeConfig.dimImages },
                    set: { store.setDarkModeDimImages($0) }
                ))
                .font(.system(size: 11.5))
            }

            // Brightness & Contrast Fine-Tuning
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Fine-Tune")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.darkModeConfig.hasCustomAdjustments {
                        Button("Reset") {
                            store.resetDarkModeAdjustments()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                }

                HStack(spacing: 8) {
                    Text("Brightness")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { store.darkModeConfig.brightness },
                            set: { store.setDarkModeBrightness($0) }
                        ),
                        in: BrowserDarkModeConfig.minBrightness...BrowserDarkModeConfig.maxBrightness,
                        step: 0.05
                    )
                    .controlSize(.small)
                    Text("\(Int((store.darkModeConfig.brightness * 100).rounded()))%")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("Contrast")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { store.darkModeConfig.contrast },
                            set: { store.setDarkModeContrast($0) }
                        ),
                        in: BrowserDarkModeConfig.minContrast...BrowserDarkModeConfig.maxContrast,
                        step: 0.05
                    )
                    .controlSize(.small)
                    Text("\(Int((store.darkModeConfig.contrast * 100).rounded()))%")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .frame(width: 304)
    }
}
