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
    @State private var autofillPopoverOpen = false
    @State private var extensionsPopoverOpen = false
    @State private var downloadsPopoverOpen = false

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

            if let tab = activeTab, let pending = tab.pendingCredentialSave {
                savePasswordBanner(store: store, tab: tab, pending: pending)
                Divider().opacity(0.4)
            }

            ZStack(alignment: .top) {
                if store.isSplitViewActive, let left = store.primaryTab, let right = store.splitTab {
                    splitBrowserCanvas(store: store, left: left, right: right)
                } else if let tab = activeTab {
                    browserPane(store: store, tab: tab, pane: .primary, isSplit: false)
                } else {
                    Color.clear
                }

                if isEditingOmnibox {
                    omniboxSuggestionsOverlay(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            await store.refreshExtensionConfig()
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
                            if let error = tab.loadError {
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

    // MARK: Slim Single-Row Omnibox Bar

    private func omniboxBar(store: BrowserStore, tab: BrowserTabSession?) -> some View {
        let downloads = WebDownloads.shared
        let matchingCreds = tab.map { store.autofill.matchingCredentials(for: $0.urlString) } ?? []
        let canAutofill = tab.map { BrowserAutofillLogic.isSecureAutofillOrigin($0.urlString) } ?? false
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.isSplitViewActive ? theme.palette.accent : theme.palette.secondaryText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTooltip(store.isSplitViewActive ? "Close Split View (⌘⌃\\)" : "Split View Side-by-Side (⌘⌃\\)")

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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? theme.palette.tertiaryText.opacity(0.45) : theme.palette.secondaryText)
                .frame(width: 26, height: 26)
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

            Toggle("Offer Keychain Password AutoFill", isOn: Binding(
                get: { store.autofillEnabled },
                set: {
                    store.autofillEnabled = $0
                    store.scheduleSave()
                }
            ))
            .font(.system(size: 12))

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
                Button("Clear \(store.currentRuntime.name) Cookies & Cache", role: .destructive) {
                    shieldPopoverOpen = false
                    Task { await store.clearBrowsingData() }
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 300)
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
        syncActiveTabChrome(store: store)
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
        let secureOrigin = BrowserAutofillLogic.isSecureAutofillOrigin(tab.urlString)
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
                    Text("AutoFill is restricted to HTTPS and localhost pages.")
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
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(cred.password, forType: .string)
                                store.showToast("Copied password for \(cred.host)", tone: .neutral)
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
