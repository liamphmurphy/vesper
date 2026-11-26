import AppKit
import Foundation
import Observation
import VesperCore
import WebKit

/// App-wide state for Vesper's internal Browser (`AppModel.browser`).
///
/// Living on `AppModel` means open web tabs, scroll positions, logged-in sessions, and active
/// persona shares stay alive when switching between Chat, Knowledge, Spaces, and Browser.
@MainActor
@Observable
final class BrowserStore {
    private(set) var tabs: [BrowserTabSession] = []
    var activeTabId: UUID?
    private(set) var bookmarks: [BrowserBookmark] = []
    private(set) var history: [BrowserHistoryEntry] = []
    var adBlockEnabled: Bool = true
    private(set) var adBlockDisabledHosts: [String] = []
    var openExternalLinksInBrowser: Bool = true
    var searchEngine: BrowserSearchEngine = .duckDuckGo
    private(set) var siteZooms: [String: Double] = [:]

    /// Server-side browser sharing config (personas, recent chats, never_share lists).
    private(set) var extensionConfig: BrowserExtensionConfig = BrowserExtensionConfig()
    private(set) var isRefreshingConfig = false

    /// Incremented by `⌘L` so the omnibox focuses and selects its text.
    var focusAddressBarTick: Int = 0

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let blocker = BrowserContentBlockerManager()
    @ObservationIgnored private var closedTabs: [BrowserTabRecord] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var sharePollTask: Task<Void, Never>?
    @ObservationIgnored private var didLoadInitialState = false

    /// Ordered tabs matching the sidebar display: pinned first, then regular tabs.
    var orderedTabs: [BrowserTabSession] {
        BrowserTabListLogic.displayOrder(tabs, isPinned: \.isPinned)
    }

    var pinnedTabs: [BrowserTabSession] {
        tabs.filter(\.isPinned)
    }

    var regularTabs: [BrowserTabSession] {
        tabs.filter { !$0.isPinned }
    }

    var activeTab: BrowserTabSession? {
        if let activeTabId, let match = tabs.first(where: { $0.id == activeTabId }) {
            return match
        }
        return orderedTabs.first
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    var anyActiveShare: Bool { tabs.contains(where: { $0.activeShare != nil }) }

    init(app: AppModel, dataDirectory: URL) {
        self.app = app
        self.storageURL = BrowserStorage.fileURL(dataDirectory: dataDirectory)
        loadPersistedState()
    }

    // MARK: Persistence

    private func loadPersistedState() {
        guard !didLoadInitialState else { return }
        didLoadInitialState = true
        let persisted = BrowserStorage.load(from: storageURL)
        bookmarks = persisted.bookmarks
        history = persisted.history
        adBlockEnabled = persisted.adBlockEnabled
        adBlockDisabledHosts = persisted.adBlockDisabledHosts
        openExternalLinksInBrowser = persisted.openExternalLinksInBrowser
        searchEngine = persisted.searchEngine
        siteZooms = persisted.siteZooms

        if persisted.tabs.isEmpty {
            let initial = createSession(record: BrowserTabRecord())
            tabs = [initial]
            activeTabId = initial.id
        } else {
            tabs = persisted.tabs.map { createSession(record: $0) }
            activeTabId = persisted.activeTabId ?? tabs.first?.id
        }

        Task { await recompileContentBlocker() }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = BrowserPersistedState(
            tabs: tabs.map(\.record),
            activeTabId: activeTabId,
            bookmarks: bookmarks,
            history: history,
            adBlockEnabled: adBlockEnabled,
            adBlockDisabledHosts: adBlockDisabledHosts,
            openExternalLinksInBrowser: openExternalLinksInBrowser,
            searchEngine: searchEngine,
            siteZooms: siteZooms
        )
        do {
            try BrowserStorage.save(snapshot, to: storageURL)
        } catch {
            vlog("browser state save failed: \(error)")
        }
    }

    // MARK: Tab Lifecycle

    private func createSession(record: BrowserTabRecord) -> BrowserTabSession {
        let session = BrowserTabSession(record: record, contentRuleList: blocker.compiledRuleList)
        session.neverShareProvider = { [weak self] in self?.extensionConfig.neverShare ?? BrowserNeverShareLists() }
        session.hostZoomProvider = { [weak self] host in
            guard let self, let normalized = BrowserPageGuard.normalizeHost(host) else { return nil }
            return self.siteZooms[normalized]
        }
        session.onOpenNewTab = { [weak self] url, isPrivate in
            self?.openURL(url, inNewTab: true, isPrivate: isPrivate)
        }
        session.onPageCommitted = { [weak self] tab in
            self?.scheduleSave()
            _ = tab
        }
        session.onPageFinished = { [weak self] tab in
            guard let self else { return }
            if !tab.isPrivate, !tab.urlString.isEmpty {
                self.history = BrowserTabListLogic.recordVisit(
                    url: tab.urlString,
                    title: tab.displayTitle,
                    in: self.history
                )
            }
            self.scheduleSave()
        }
        session.onStateChanged = { [weak self] in
            self?.scheduleSave()
        }
        session.onTabShouldClose = { [weak self] tab in
            self?.closeTab(tab.id)
        }
        session.onSnapshotDue = { [weak self] tab in
            guard let self else { return }
            Task { await self.sendSnapshot(for: tab) }
        }
        session.onStopShare = { [weak self] tab, reason in
            guard let self else { return }
            Task { await self.stopShare(for: tab, reason: reason) }
        }
        session.webView.contextCallbacks = BrowserWKWebView.ContextCallbacks(
            onAskPersona: { [weak self, weak session] in
                guard let self, let session else { return }
                Task { await self.askPersonaFromContextMenu(tab: session) }
            },
            onClipToKnowledge: { [weak self, weak session] in
                guard let self, let session else { return }
                Task { await self.clipToKnowledge(tab: session, includeSelectionOnlyIfPresent: true) }
            },
            onSaveLink: { [weak self, weak session] in
                guard let self, let session else { return }
                Task { await self.saveToReadingList(tab: session) }
            },
            onCopyMarkdownQuote: { [weak self, weak session] in
                guard let self, let session else { return }
                Task { await self.copyMarkdownQuote(tab: session) }
            },
            onScreenshotToNotes: { [weak self, weak session] in
                guard let self, let session else { return }
                Task { await self.screenshotToKnowledge(tab: session) }
            },
            onOpenInSafari: { [weak session] in
                guard let session, let url = URL(string: session.urlString), BrowserURLResolver.isWebURL(url) else { return }
                NSWorkspace.shared.open(url)
            }
        )
        return session
    }

    @discardableResult
    func newTab(url: URL? = nil, isPrivate: Bool = false, select: Bool = true) -> BrowserTabSession {
        let record = BrowserTabRecord(
            url: url?.absoluteString ?? "",
            title: isPrivate ? "Private Tab" : "New Tab",
            isPinned: false,
            isPrivate: isPrivate
        )
        let session = createSession(record: record)
        tabs.append(session)
        if select {
            activeTabId = session.id
            if url == nil {
                focusAddressBarTick &+= 1
            }
        }
        scheduleSave()
        return session
    }

    /// Opens a URL in the active empty tab (if any) or a new tab, optionally reusing an existing
    /// tab already showing the exact URL.
    func openURL(_ url: URL, inNewTab: Bool = true, isPrivate: Bool = false, reuseExisting: Bool = false) {
        guard BrowserURLResolver.isWebURL(url) else { return }
        if reuseExisting, !isPrivate, let existing = tabs.first(where: { !$0.isPrivate && $0.urlString == url.absoluteString }) {
            activeTabId = existing.id
            return
        }
        if !inNewTab, let current = activeTab {
            current.load(url)
            return
        }
        if !isPrivate, let current = activeTab, !current.isPrivate, !current.hasLoadedPage {
            current.load(url)
            return
        }
        _ = newTab(url: url, isPrivate: isPrivate, select: true)
    }

    func navigateActiveTab(input: String) {
        guard let url = BrowserURLResolver.resolve(input, searchEngine: searchEngine) else { return }
        if let active = activeTab {
            active.load(url)
        } else {
            _ = newTab(url: url, select: true)
        }
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabId = id
        scheduleSave()
    }

    func selectNumberedTab(_ number: Int) {
        let ordered = orderedTabs
        guard let idx = BrowserTabListLogic.indexForNumberedShortcut(number, count: ordered.count) else { return }
        selectTab(ordered[idx].id)
    }

    func selectNextTab() {
        let ordered = orderedTabs
        let currentIdx = activeTabId.flatMap { id in ordered.firstIndex(where: { $0.id == id }) }
        guard let next = BrowserTabListLogic.nextIndex(after: currentIdx, count: ordered.count) else { return }
        selectTab(ordered[next].id)
    }

    func selectPreviousTab() {
        let ordered = orderedTabs
        let currentIdx = activeTabId.flatMap { id in ordered.firstIndex(where: { $0.id == id }) }
        guard let prev = BrowserTabListLogic.previousIndex(before: currentIdx, count: ordered.count) else { return }
        selectTab(ordered[prev].id)
    }

    func closeActiveTab() {
        guard let active = activeTab else { return }
        closeTab(active.id)
    }

    func closeTab(_ id: UUID) {
        let ordered = orderedTabs
        guard let rawIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs.remove(at: rawIndex)
        if removed.activeShare != nil {
            Task { await stopShare(for: removed, reason: "tab_closed") }
        }
        if !removed.isPrivate, !removed.urlString.isEmpty {
            closedTabs.append(removed.record)
            if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
        }
        removed.teardown()

        if tabs.isEmpty {
            let fresh = createSession(record: BrowserTabRecord())
            tabs = [fresh]
            activeTabId = fresh.id
            focusAddressBarTick &+= 1
        } else if activeTabId == id {
            let oldOrderedIdx = ordered.firstIndex(where: { $0.id == id }) ?? 0
            let nextOrdered = orderedTabs
            let targetIdx = min(oldOrderedIdx, max(0, nextOrdered.count - 1))
            activeTabId = nextOrdered[targetIdx].id
        }
        scheduleSave()
    }

    func closeOtherTabs(keeping id: UUID) {
        let doomed = tabs.filter { $0.id != id && !$0.isPinned }.map(\.id)
        for tabId in doomed {
            closeTab(tabId)
        }
    }

    func reopenClosedTab() {
        guard let record = closedTabs.popLast() else { return }
        let restored = BrowserTabRecord(
            id: UUID(),
            url: record.url,
            title: record.title,
            isPinned: false,
            isPrivate: false,
            zoom: record.zoom
        )
        let session = createSession(record: restored)
        tabs.append(session)
        activeTabId = session.id
        scheduleSave()
    }

    func duplicateTab(_ id: UUID) {
        guard let source = tabs.first(where: { $0.id == id }) else { return }
        let url = URL(string: source.urlString)
        _ = newTab(url: url, isPrivate: source.isPrivate, select: true)
    }

    func togglePin(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isPinned.toggle()
        scheduleSave()
    }

    func focusAddressBar() {
        focusAddressBarTick &+= 1
    }

    // MARK: Zoom & Ad-Block

    func adjustZoom(delta: Double, for tab: BrowserTabSession? = nil) {
        guard let tab = tab ?? activeTab else { return }
        let next = min(3.0, max(0.3, ((tab.zoom + delta) * 10).rounded() / 10))
        applyZoom(next, to: tab)
    }

    func resetZoom(for tab: BrowserTabSession? = nil) {
        guard let tab = tab ?? activeTab else { return }
        applyZoom(1.0, to: tab)
    }

    private func applyZoom(_ zoom: Double, to tab: BrowserTabSession) {
        tab.setZoom(zoom)
        if !tab.isPrivate, let host = BrowserPageGuard.normalizeHost(tab.urlString) {
            if abs(zoom - 1.0) < 0.01 {
                siteZooms.removeValue(forKey: host)
            } else {
                siteZooms[host] = zoom
            }
            scheduleSave()
        }
    }

    func isAdBlockActive(for urlString: String) -> Bool {
        BrowserContentBlockerRules.isAdBlockActive(
            globalEnabled: adBlockEnabled,
            host: urlString,
            disabledHosts: adBlockDisabledHosts
        )
    }

    func setAdBlockEnabled(_ enabled: Bool) {
        adBlockEnabled = enabled
        scheduleSave()
        Task {
            await recompileContentBlocker()
            activeTab?.reload()
        }
    }

    func toggleAdBlock(forHost rawHost: String) {
        guard let host = BrowserPageGuard.normalizeHost(rawHost) else { return }
        if let idx = adBlockDisabledHosts.firstIndex(of: host) {
            adBlockDisabledHosts.remove(at: idx)
        } else {
            adBlockDisabledHosts.append(host)
        }
        scheduleSave()
        Task {
            await recompileContentBlocker()
            activeTab?.reload()
        }
    }

    private func recompileContentBlocker() async {
        let ruleList = await blocker.compile(enabled: adBlockEnabled, disabledHosts: adBlockDisabledHosts)
        for tab in tabs {
            tab.applyContentRuleList(ruleList)
        }
    }

    // MARK: Bookmarks & History

    func isBookmarked(_ urlString: String) -> Bool {
        guard !urlString.isEmpty else { return false }
        return bookmarks.contains(where: { $0.url == urlString })
    }

    func toggleBookmark(for tab: BrowserTabSession? = nil) {
        guard let tab = tab ?? activeTab, !tab.urlString.isEmpty else { return }
        if let idx = bookmarks.firstIndex(where: { $0.url == tab.urlString }) {
            bookmarks.remove(at: idx)
            showToast("Removed bookmark", tone: .neutral)
        } else {
            bookmarks.insert(BrowserBookmark(url: tab.urlString, title: tab.displayTitle), at: 0)
            showToast("Bookmarked \(tab.displayTitle)", tone: .success)
        }
        scheduleSave()
    }

    func removeBookmark(id: String) {
        bookmarks.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearHistory() {
        history.removeAll()
        scheduleSave()
    }

    func removeHistoryEntry(id: String) {
        history.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearBrowsingData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await BrowserWebViewFactory.persistentStore.removeData(ofTypes: types, modifiedSince: .distantPast)
        showToast("Cleared browser cookies and cache", tone: .neutral)
    }

    // MARK: Server Extension API Integration (Share, Ask, Clip, Never-Share)

    private func makeExtensionClient() -> BrowserExtensionClient? {
        guard let conn = app?.connection else { return nil }
        let apiClient = APIClient(baseURL: conn.baseURL, sessionToken: conn.sessionToken)
        return BrowserExtensionClient(baseURL: conn.baseURL) { forceRefresh in
            try await SafariExtensionLink.token(using: apiClient, forceRefresh: forceRefresh)
        }
    }

    func refreshExtensionConfig() async {
        guard let client = makeExtensionClient() else { return }
        isRefreshingConfig = true
        defer { isRefreshingConfig = false }
        do {
            let cfg = try await client.fetchConfig()
            extensionConfig = cfg
            // Sync read logs and server-side stops back to live tabs.
            let activeById = Dictionary(uniqueKeysWithValues: cfg.shares.map { ($0.id, $0) })
            for tab in tabs {
                if let share = tab.activeShare {
                    if let updated = activeById[share.id] {
                        tab.activeShare = updated
                    } else {
                        tab.activeShare = nil
                        tab.shareStartURL = nil
                    }
                }
            }
            updateSharePolling()
        } catch {
            vlog("browser extension config refresh failed: \(error)")
        }
    }

    func pageShareCheck(for tab: BrowserTabSession) -> BrowserPageShareCheck {
        BrowserPageGuard.shareablePage(
            url: tab.urlString,
            isPrivate: tab.isPrivate,
            neverShare: extensionConfig.neverShare
        )
    }

    /// Starts sharing a tab with a chat (such as the active Companion chat) or a persona.
    func startShare(
        for tab: BrowserTabSession,
        chatId: String?,
        personaId: String?,
        until: String,
        includeScreenshot: Bool,
        openInCompanion: Bool = true
    ) async {
        guard let client = makeExtensionClient() else {
            showToast("Connect Vesper before sharing tabs", tone: .error)
            return
        }
        let check = pageShareCheck(for: tab)
        guard check.ok else {
            tab.shareError = check.reason
            showToast(check.reason ?? "This page can't be shared", tone: .error)
            return
        }
        tab.shareError = nil
        let extracted = await tab.extractPageContent()
        let screenshot = includeScreenshot ? await tab.captureSnapshotJPEGBase64() : nil
        let snap = BrowserSnapshotPayload(
            url: extracted.url,
            title: extracted.title,
            text: extracted.text,
            screenshot: screenshot,
            incognito: tab.isPrivate
        )
        let req = BrowserShareStartRequest(
            snapshot: snap,
            chatId: chatId,
            personaId: personaId,
            tabId: tab.id.uuidString,
            until: until,
            includeScreenshot: includeScreenshot
        )
        do {
            let share = try await client.startShare(req)
            tab.activeShare = share
            tab.shareStartURL = extracted.url
            updateSharePolling()
            if openInCompanion {
                app?.keyController?.openCompanionChat(share.chatId)
            }
            showToast("Sharing tab with \(share.chatTitle.isEmpty ? "chat" : share.chatTitle)", tone: .success)
        } catch {
            let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
            tab.shareError = msg
            showToast(msg, tone: .error)
        }
    }

    func sendSnapshot(for tab: BrowserTabSession) async {
        guard let share = tab.activeShare, let client = makeExtensionClient() else { return }
        let check = pageShareCheck(for: tab)
        guard check.ok else {
            await stopShare(for: tab, reason: "never_share")
            return
        }
        let extracted = await tab.extractPageContent()
        let screenshot = share.includeScreenshot ? await tab.captureSnapshotJPEGBase64() : nil
        let snap = BrowserSnapshotPayload(
            url: extracted.url,
            title: extracted.title,
            text: extracted.text,
            screenshot: screenshot,
            incognito: tab.isPrivate
        )
        do {
            let updated = try await client.sendSnapshot(shareId: share.id, snapshot: snap)
            tab.activeShare = updated
        } catch {
            vlog("browser share snapshot failed: \(error)")
        }
    }

    func stopShare(for tab: BrowserTabSession, reason: String = "person") async {
        guard let share = tab.activeShare else { return }
        tab.activeShare = nil
        tab.shareStartURL = nil
        updateSharePolling()
        guard let client = makeExtensionClient() else { return }
        do {
            _ = try await client.stopShare(shareId: share.id, reason: reason)
            if reason == "person" {
                showToast("Stopped sharing tab", tone: .neutral)
            }
        } catch {
            vlog("browser share stop failed: \(error)")
        }
    }

    func addNeverShare(host: String) async {
        guard let client = makeExtensionClient() else { return }
        do {
            extensionConfig = try await client.addNeverShare(host: host)
            // Stop any live shares on that host locally too.
            for tab in tabs where tab.activeShare != nil {
                if !pageShareCheck(for: tab).ok {
                    tab.activeShare = nil
                    tab.shareStartURL = nil
                }
            }
            updateSharePolling()
            showToast("Added \(host) to never-share list", tone: .neutral)
        } catch {
            showToast((error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error)
        }
    }

    func removeNeverShare(host: String) async {
        guard let client = makeExtensionClient() else { return }
        do {
            extensionConfig = try await client.removeNeverShare(host: host)
            showToast("Removed \(host) from never-share list", tone: .neutral)
        } catch {
            showToast((error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error)
        }
    }

    private func updateSharePolling() {
        if !anyActiveShare {
            sharePollTask?.cancel()
            sharePollTask = nil
            return
        }
        guard sharePollTask == nil else { return }
        sharePollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.anyActiveShare {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self.pollActiveShares()
            }
            self?.sharePollTask = nil
        }
    }

    private func pollActiveShares() async {
        guard let client = makeExtensionClient() else { return }
        for tab in tabs {
            guard let share = tab.activeShare else { continue }
            do {
                let updated = try await client.getShare(id: share.id)
                if updated.stoppedAt != nil {
                    tab.activeShare = nil
                    tab.shareStartURL = nil
                } else {
                    tab.activeShare = updated
                }
            } catch {
                // Keep trying on transient network blips.
            }
        }
        if !anyActiveShare {
            sharePollTask?.cancel()
            sharePollTask = nil
        }
    }

    // MARK: Ask, Clip, Screenshot & Quote Actions

    func askAboutPage(tab: BrowserTabSession, prompt: String, personaId: String?, openInCompanion: Bool = true) async {
        guard let client = makeExtensionClient() else {
            showToast("Connect Vesper to ask a persona", tone: .error)
            return
        }
        let check = pageShareCheck(for: tab)
        guard check.ok else {
            showToast(check.reason ?? "This page can't be shared", tone: .error)
            return
        }
        let extracted = await tab.extractPageContent()
        let req = BrowserAskRequest(
            personaId: personaId,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Explain this." : prompt,
            url: extracted.url,
            title: extracted.title,
            selection: extracted.selection,
            incognito: tab.isPrivate
        )
        do {
            let reply = try await client.ask(req)
            if openInCompanion {
                app?.keyController?.openCompanionChat(reply.chatId)
            } else {
                app?.keyController?.send(.navigate(path: reply.href))
            }
            showToast("Asked persona about \(tab.displayTitle)", tone: .success)
        } catch {
            showToast((error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error)
        }
    }

    private func askPersonaFromContextMenu(tab: BrowserTabSession) async {
        let defaultPersona = extensionConfig.personas.first(where: \.isDefault) ?? extensionConfig.personas.first
        await askAboutPage(tab: tab, prompt: "Explain this.", personaId: defaultPersona?.id, openInCompanion: true)
    }

    func clipToKnowledge(tab: BrowserTabSession, includeSelectionOnlyIfPresent: Bool = true) async {
        guard let client = makeExtensionClient() else {
            showToast("Connect Vesper to clip pages", tone: .error)
            return
        }
        let check = pageShareCheck(for: tab)
        guard check.ok else {
            showToast(check.reason ?? "This page can't be clipped", tone: .error)
            return
        }
        let extracted = await tab.extractPageContent()
        let selection = includeSelectionOnlyIfPresent ? extracted.selection : ""
        do {
            let reply = try await client.clip(BrowserClipRequest(
                as: .note,
                url: extracted.url,
                title: extracted.title,
                selection: selection,
                incognito: tab.isPrivate
            ))
            app?.system.store.invalidate(KnowledgeAPI.invalidation)
            showToast(
                selection.isEmpty ? "Saved page to Knowledge › Clippings" : "Saved selection to Knowledge › Clippings",
                tone: .success,
                actionLabel: "Open"
            ) { [weak self] event in
                if event == .action {
                    self?.app?.openVesperTab(path: reply.href, nextTo: self?.app?.keyController?.window)
                }
            }
        } catch {
            showToast((error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error)
        }
    }

    func saveToReadingList(tab: BrowserTabSession) async {
        guard let client = makeExtensionClient() else {
            showToast("Connect Vesper to save links", tone: .error)
            return
        }
        let check = pageShareCheck(for: tab)
        guard check.ok else {
            showToast(check.reason ?? "This page can't be saved", tone: .error)
            return
        }
        let extracted = await tab.extractPageContent()
        do {
            let reply = try await client.clip(BrowserClipRequest(
                as: .link,
                url: extracted.url,
                title: extracted.title,
                selection: extracted.selection,
                incognito: tab.isPrivate
            ))
            app?.system.store.invalidate(QueryInvalidation(resources: ["library"]))
            let msg = reply.state == "already_saved" ? "Already in Saved Links" : "Saved to Reading List"
            showToast(msg, tone: .success)
        } catch {
            showToast((error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error)
        }
    }

    func copyMarkdownQuote(tab: BrowserTabSession) async {
        let selection = await tab.extractSelection()
        let quote = BrowserKnowledgeFormatter.markdownQuote(
            selection: selection,
            title: tab.displayTitle,
            url: tab.urlString
        )
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(quote, forType: .string)
        showToast(selection.isEmpty ? "Copied Markdown link" : "Copied Markdown quote", tone: .neutral)
    }

    /// Captures a permission-free `WKWebView` screenshot, uploads it as a Knowledge asset,
    /// and creates a clipping note embedding the image + source URL.
    func screenshotToKnowledge(tab: BrowserTabSession, caption: String? = nil) async {
        guard let apiClient = app?.system.store.client else {
            showToast("Connect Vesper to save screenshots", tone: .error)
            return
        }
        guard tab.hasLoadedPage else {
            showToast("Open a web page first", tone: .error)
            return
        }
        guard let pngData = await tab.captureScreenshotPNG() else {
            showToast("Couldn't capture page screenshot", tone: .error)
            return
        }
        let filename = Screenshot.fileName(Date())
        do {
            let uploaded = try await apiClient.send(KnowledgeAPI.uploadAsset(data: pngData, filename: filename))
            let host = BrowserURLResolver.displayHost(for: tab.urlString)
            let noteTitle = tab.displayTitle.isEmpty ? "Screenshot of \(host)" : "\(tab.displayTitle) (Screenshot)"
            let body = BrowserKnowledgeFormatter.screenshotNoteBody(
                title: tab.displayTitle,
                url: tab.urlString,
                assetRef: uploaded.ref,
                caption: caption
            )
            let props: [String: JSONValue] = [
                "type": .string("literature"),
                "source": .string(tab.urlString),
                "source_title": .string(tab.displayTitle),
                "source_site": .string(host),
                "clipped_from": .string("browser"),
            ]
            let page = try await apiClient.send(KnowledgeAPI.createPage(KnowledgePageInput(
                title: noteTitle,
                path: "Clippings/\(Self.safeFileSegment(noteTitle))-\(Int(Date().timeIntervalSince1970))",
                bodyMd: body,
                properties: props
            )))
            app?.system.store.invalidate(KnowledgeAPI.invalidation)
            showToast("Saved screenshot to Knowledge › Clippings", tone: .success, actionLabel: "Open") { [weak self] event in
                if event == .action {
                    self?.app?.openVesperTab(path: "/knowledge/\(page.id)", nextTo: self?.app?.keyController?.window)
                }
            }
        } catch {
            showToast((error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error)
        }
    }

    /// Captures a permission-free `WKWebView` screenshot and offers it to Vesper's Send-to-Chat picker.
    func screenshotToChat(tab: BrowserTabSession) async {
        guard tab.hasLoadedPage else {
            showToast("Open a web page first", tone: .error)
            return
        }
        guard let pngData = await tab.captureScreenshotPNG() else {
            showToast("Couldn't capture page screenshot", tone: .error)
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-browser-shot-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fileURL = dir.appendingPathComponent(Screenshot.fileName(Date()))
            try pngData.write(to: fileURL, options: .atomic)
            app?.aux.files.offer([fileURL.path], cleanup: {
                try? FileManager.default.removeItem(at: dir)
            })
        } catch {
            showToast("Couldn't prepare screenshot: \(error.localizedDescription)", tone: .error)
        }
    }

    func copyScreenshot(tab: BrowserTabSession) async {
        guard tab.hasLoadedPage, let pngData = await tab.captureScreenshotPNG(), let image = NSImage(data: pngData) else {
            showToast("Couldn't capture page screenshot", tone: .error)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        showToast("Copied page screenshot", tone: .neutral)
    }

    func saveFullPagePDF(tab: BrowserTabSession) async {
        guard tab.hasLoadedPage, let pdfData = await tab.captureFullPagePDF() else {
            showToast("Couldn't render PDF for this page", tone: .error)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(Self.safeFileSegment(tab.displayTitle)).pdf"
        let response: NSApplication.ModalResponse
        if let window = app?.keyController?.window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let dest = panel.url else { return }
        do {
            try pdfData.write(to: dest, options: .atomic)
            showToast("Saved PDF", tone: .success)
        } catch {
            showToast("Couldn't save PDF: \(error.localizedDescription)", tone: .error)
        }
    }

    private static func safeFileSegment(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let filtered = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(filtered)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        let prefix = String(collapsed.prefix(64))
        return prefix.isEmpty ? "page" : prefix
    }

    private func showToast(
        _ title: String,
        tone: ToastTone,
        actionLabel: String? = nil,
        onEvent: @escaping @MainActor (ToastEventKind) -> Void = { _ in }
    ) {
        let toast = ToastItemModel(
            id: "browser.\(UUID().uuidString.prefix(8))",
            title: title,
            tone: tone,
            actionLabel: actionLabel
        )
        app?.keyController?.showNativeToast(toast, onEvent: onEvent)
    }
}
