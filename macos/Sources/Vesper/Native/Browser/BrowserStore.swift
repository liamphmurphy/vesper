import AppKit
import Foundation
import Observation
import VesperCore
import WebKit

/// Live runtime state for one Browser profile (isolated tabs, groups, split view, bookmarks,
/// history, WebExtensions, content blocker, and Keychain AutoFill scope).
@MainActor
@Observable
final class BrowserProfileRuntime: Identifiable {
    let id: UUID
    var name: String
    var icon: String
    var color: BrowserProfileColor
    let dataStoreID: UUID

    var tabs: [BrowserTabSession] = []
    var activeTabId: UUID?
    var splitTabId: UUID?
    var focusedPane: BrowserStore.SplitPane = .primary
    var splitRatio: Double = 0.5
    var tabGroups: [BrowserTabGroup] = []
    var bookmarks: [BrowserBookmark] = []
    var history: [BrowserHistoryEntry] = []
    var adBlockDisabledHosts: [String] = []
    var siteZooms: [String: Double] = [:]
    var autofillNeverSaveHosts: [String] = []
    var httpsOnlyExceptions: [String] = []
    var lockdownEnabledHosts: [String] = []
    var lockdownDisabledHosts: [String] = []
    var javascriptDisabledHosts: [String] = []
    var sitePermissions: [String: [String: BrowserPermissionSetting]] = [:]
    var proxyConfig: BrowserProxyConfig = .none

    let extensionHost: BrowserExtensionHost
    let autofill: BrowserAutofillManager

    @ObservationIgnored var closedTabs: [BrowserTabRecord] = []

    init(
        profile: BrowserProfile,
        dataDirectory: URL,
        credentialStore: any BrowserCredentialStore
    ) {
        self.id = profile.id
        self.name = profile.name
        self.icon = profile.icon
        self.color = profile.color
        self.dataStoreID = profile.dataStoreID
        self.splitRatio = profile.splitRatio
        self.tabGroups = profile.tabGroups
        self.bookmarks = profile.bookmarks
        self.history = profile.history
        self.adBlockDisabledHosts = profile.adBlockDisabledHosts
        self.siteZooms = profile.siteZooms
        self.autofillNeverSaveHosts = profile.autofillNeverSaveHosts
        self.httpsOnlyExceptions = profile.httpsOnlyExceptions
        self.lockdownEnabledHosts = profile.lockdownEnabledHosts
        self.lockdownDisabledHosts = profile.lockdownDisabledHosts
        self.javascriptDisabledHosts = profile.javascriptDisabledHosts
        self.sitePermissions = profile.sitePermissions
        self.proxyConfig = profile.proxyConfig
        BrowserWebViewFactory.applyProxy(profile.proxyConfig, toProfileID: profile.dataStoreID)
        self.extensionHost = BrowserExtensionHost(
            profileID: profile.id,
            dataStoreID: profile.dataStoreID,
            dataDirectory: dataDirectory,
            initialRecords: profile.extensions
        )
        self.autofill = BrowserAutofillManager(profileID: profile.id, store: credentialStore)
    }

    func persistedProfile() -> BrowserProfile {
        BrowserProfile(
            id: id,
            name: name,
            icon: icon,
            color: color,
            dataStoreID: dataStoreID,
            tabs: tabs.map(\.record),
            activeTabId: activeTabId,
            splitTabId: splitTabId,
            splitRatio: splitRatio,
            tabGroups: tabGroups,
            bookmarks: bookmarks,
            history: history,
            adBlockDisabledHosts: adBlockDisabledHosts,
            siteZooms: siteZooms,
            extensions: extensionHost.records,
            autofillNeverSaveHosts: autofillNeverSaveHosts,
            httpsOnlyExceptions: httpsOnlyExceptions,
            lockdownEnabledHosts: lockdownEnabledHosts,
            lockdownDisabledHosts: lockdownDisabledHosts,
            javascriptDisabledHosts: javascriptDisabledHosts,
            sitePermissions: sitePermissions,
            proxyConfig: proxyConfig
        )
    }
}

/// App-wide state for Vesper's internal Browser (`AppModel.browser`).
///
/// Living on `AppModel` means open web tabs, profiles, split panes, logged-in sessions,
/// extensions, and active persona shares stay alive when switching between Chat, Knowledge,
/// Spaces, and Browser.
@MainActor
@Observable
final class BrowserStore {
    enum SplitPane: Equatable {
        case primary
        case secondary
    }

    private(set) var runtimes: [BrowserProfileRuntime] = []
    var activeProfileId: UUID = BrowserProfile.defaultProfileID

    var adBlockEnabled: Bool = true
    var adBlockConfig: BrowserAdBlockConfig = .default
    var securityConfig: BrowserSecurityConfig = .default
    var openExternalLinksInBrowser: Bool = true
    var searchEngine: BrowserSearchEngine = .duckDuckGo
    var autofillEnabled: Bool = true

    /// Shared Wipr/uBO-style multi-list content blocker & Phase B scriptlet engine.
    let adBlockEngine: BrowserAdBlockEngine

    /// Server-side browser sharing config (personas, recent chats, never_share lists).
    private(set) var extensionConfig: BrowserExtensionConfig = BrowserExtensionConfig()
    private(set) var isRefreshingConfig = false

    /// UI triggers incremented by menu shortcuts so SwiftUI opens/focuses the matching control.
    var focusAddressBarTick: Int = 0
    var openAutofillPopoverTick: Int = 0
    var openExtensionsPopoverTick: Int = 0
    var regionCaptureTabId: UUID?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let dataDirectory: URL
    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let credentialStore: any BrowserCredentialStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var sharePollTask: Task<Void, Never>?
    @ObservationIgnored private var didLoadInitialState = false

    // MARK: Active Profile Convenience Accessors

    var currentRuntime: BrowserProfileRuntime {
        if let match = runtimes.first(where: { $0.id == activeProfileId }) {
            return match
        }
        return runtimes[0]
    }

    var profiles: [BrowserProfileRuntime] { runtimes }
    var tabs: [BrowserTabSession] { currentRuntime.tabs }
    var activeTabId: UUID? {
        get { currentRuntime.activeTabId }
        set { currentRuntime.activeTabId = newValue }
    }
    var splitTabId: UUID? {
        get { currentRuntime.splitTabId }
        set { currentRuntime.splitTabId = newValue }
    }
    var focusedPane: SplitPane {
        get { currentRuntime.focusedPane }
        set { currentRuntime.focusedPane = newValue }
    }
    var splitRatio: Double {
        get { currentRuntime.splitRatio }
        set { currentRuntime.splitRatio = min(0.8, max(0.2, newValue)) }
    }
    var tabGroups: [BrowserTabGroup] { currentRuntime.tabGroups }
    var bookmarks: [BrowserBookmark] { currentRuntime.bookmarks }
    var history: [BrowserHistoryEntry] { currentRuntime.history }
    var adBlockDisabledHosts: [String] { currentRuntime.adBlockDisabledHosts }
    var siteZooms: [String: Double] { currentRuntime.siteZooms }
    var extensionHost: BrowserExtensionHost { currentRuntime.extensionHost }
    var autofill: BrowserAutofillManager { currentRuntime.autofill }

    /// Ordered tabs matching the sidebar display: pinned first, then grouped tabs, then ungrouped tabs.
    var orderedTabs: [BrowserTabSession] {
        BrowserTabGroupLogic.displayOrder(
            tabs: currentRuntime.tabs,
            groups: currentRuntime.tabGroups,
            isPinned: \.isPinned,
            groupId: \.groupId
        )
    }

    var pinnedTabs: [BrowserTabSession] { currentRuntime.tabs.filter(\.isPinned) }
    var regularTabs: [BrowserTabSession] { currentRuntime.tabs.filter { !$0.isPinned } }

    /// Primary (left) tab in the active profile.
    var primaryTab: BrowserTabSession? {
        if let activeId = currentRuntime.activeTabId,
           let match = currentRuntime.tabs.first(where: { $0.id == activeId })
        {
            return match
        }
        return orderedTabs.first
    }

    /// Secondary (right) tab when Split View is active.
    var splitTab: BrowserTabSession? {
        guard let splitId = currentRuntime.splitTabId,
              splitId != primaryTab?.id,
              let match = currentRuntime.tabs.first(where: { $0.id == splitId })
        else { return nil }
        return match
    }

    var isSplitViewActive: Bool { splitTab != nil }

    /// The tab currently targeted by the omnibox, keyboard shortcuts, Find, Reader Mode, and Share.
    /// In single-pane mode this is `primaryTab`; in Split View this is whichever pane is focused.
    var activeTab: BrowserTabSession? {
        if currentRuntime.focusedPane == .secondary, let right = splitTab {
            return right
        }
        return primaryTab
    }

    var canReopenClosedTab: Bool { !currentRuntime.closedTabs.isEmpty }

    var anyActiveShare: Bool {
        runtimes.contains { runtime in runtime.tabs.contains(where: { $0.activeShare != nil }) }
    }

    init(
        app: AppModel,
        dataDirectory: URL,
        credentialStore: any BrowserCredentialStore = KeychainBrowserCredentialStore(),
        adBlockFetcher: BrowserFilterListFetcher? = nil
    ) {
        self.app = app
        self.dataDirectory = dataDirectory
        self.storageURL = BrowserStorage.fileURL(dataDirectory: dataDirectory)
        self.credentialStore = credentialStore
        self.adBlockEngine = BrowserAdBlockEngine(dataDirectory: dataDirectory, fetcher: adBlockFetcher)
        loadPersistedState()
    }

    // MARK: Persistence

    private func loadPersistedState() {
        guard !didLoadInitialState else { return }
        didLoadInitialState = true
        let persisted = BrowserStorage.load(from: storageURL)
        adBlockEnabled = persisted.adBlockEnabled
        adBlockConfig = persisted.adBlockConfig
        securityConfig = persisted.securityConfig
        openExternalLinksInBrowser = persisted.openExternalLinksInBrowser
        searchEngine = persisted.searchEngine
        autofillEnabled = persisted.autofillEnabled

        let sourceProfiles = persisted.profiles.isEmpty ? [BrowserProfile.defaultPersonal()] : persisted.profiles
        runtimes = sourceProfiles.map { buildRuntime(from: $0) }
        if let activeID = persisted.activeProfileId, runtimes.contains(where: { $0.id == activeID }) {
            activeProfileId = activeID
        } else {
            activeProfileId = runtimes[0].id
        }

        Task {
            await recompileAdBlockAndApply()
            if adBlockEnabled && adBlockEngine.needsAutoUpdate(config: adBlockConfig) {
                await refreshAdBlockLists(silent: true)
            }
        }
        for runtime in runtimes {
            Task {
                await runtime.extensionHost.loadAllEnabledExtensions()
            }
        }
    }

    private func buildRuntime(from profile: BrowserProfile) -> BrowserProfileRuntime {
        let runtime = BrowserProfileRuntime(
            profile: profile,
            dataDirectory: dataDirectory,
            credentialStore: credentialStore
        )
        wireExtensionHost(runtime.extensionHost, for: runtime)

        if profile.tabs.isEmpty {
            let initial = createSession(record: BrowserTabRecord(), in: runtime)
            runtime.tabs = [initial]
            runtime.activeTabId = initial.id
            runtime.extensionHost.notifyTabOpened(initial)
        } else {
            runtime.tabs = profile.tabs.map { createSession(record: $0, in: runtime) }
            runtime.activeTabId = profile.activeTabId ?? runtime.tabs.first?.id
            if let splitID = profile.splitTabId,
               splitID != runtime.activeTabId,
               runtime.tabs.contains(where: { $0.id == splitID })
            {
                runtime.splitTabId = splitID
            }
            for tab in runtime.tabs {
                runtime.extensionHost.notifyTabOpened(tab)
            }
        }
        return runtime
    }

    private func wireExtensionHost(_ host: BrowserExtensionHost, for runtime: BrowserProfileRuntime) {
        host.tabsProvider = { [weak runtime] in runtime?.tabs ?? [] }
        host.activeTabProvider = { [weak self, weak runtime] in
            guard let self, let runtime else { return nil }
            // While `loadPersistedState` builds runtimes, `runtimes` is still empty, so
            // `activeTab` (via `currentRuntime`) must not be used until this runtime is registered.
            if runtime.id == self.activeProfileId, self.runtimes.contains(where: { $0 === runtime }) {
                return self.activeTab
            }
            return runtime.tabs.first(where: { $0.id == runtime.activeTabId }) ?? runtime.tabs.first
        }
        host.hostWindowProvider = { [weak self] in self?.app?.keyController?.window }
        host.onOpenTab = { [weak self, weak runtime] url, isPrivate, activate in
            guard let self, let runtime else { return nil }
            return self.newTab(url: url, isPrivate: isPrivate, select: activate, in: runtime)
        }
        host.onActivateTab = { [weak self, weak runtime] tabId in
            guard let self, let runtime else { return }
            if runtime.id != self.activeProfileId {
                self.switchProfile(to: runtime.id)
            }
            self.selectTab(tabId)
        }
        host.onCloseTab = { [weak self, weak runtime] tabId in
            guard let self, let runtime else { return }
            self.closeTab(tabId, in: runtime)
        }
        host.onDuplicateTab = { [weak self, weak runtime] tabId, activate in
            guard let self, let runtime,
                  let source = runtime.tabs.first(where: { $0.id == tabId })
            else { return nil }
            return self.newTab(url: URL(string: source.urlString), isPrivate: source.isPrivate, select: activate, in: runtime)
        }
        host.onSetPinned = { [weak self, weak runtime] tabId, pinned in
            guard let self, let runtime,
                  let tab = runtime.tabs.first(where: { $0.id == tabId })
            else { return }
            tab.isPinned = pinned
            runtime.extensionHost.notifyTabChanged([.pinned], for: tab)
            self.scheduleSave()
        }
        host.onRecordsChanged = { [weak self] _ in
            self?.scheduleSave()
        }
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
        let persistedProfiles = runtimes.map { $0.persistedProfile() }
        let active = currentRuntime
        let snapshot = BrowserPersistedState(
            tabs: active.tabs.map(\.record),
            activeTabId: active.activeTabId,
            bookmarks: active.bookmarks,
            history: active.history,
            adBlockEnabled: adBlockEnabled,
            adBlockDisabledHosts: active.adBlockDisabledHosts,
            openExternalLinksInBrowser: openExternalLinksInBrowser,
            searchEngine: searchEngine,
            siteZooms: active.siteZooms,
            profiles: persistedProfiles,
            activeProfileId: activeProfileId,
            autofillEnabled: autofillEnabled,
            adBlockConfig: adBlockConfig,
            securityConfig: securityConfig
        )
        do {
            try BrowserStorage.save(snapshot, to: storageURL)
        } catch {
            vlog("browser state save failed: \(error)")
        }
    }

    // MARK: Profiles

    func switchProfile(to id: UUID) {
        guard runtimes.contains(where: { $0.id == id }), activeProfileId != id else { return }
        regionCaptureTabId = nil
        activeProfileId = id
        currentRuntime.autofill.reload()
        currentRuntime.extensionHost.rebuildToolbarItems()
        scheduleSave()
        showToast("Switched to \(currentRuntime.name) profile", tone: .neutral)
    }

    @discardableResult
    func createProfile(name: String, icon: String, color: BrowserProfileColor) -> BrowserProfileRuntime {
        let existing = runtimes.map { $0.persistedProfile() }
        let profile = BrowserProfileLogic.makeProfile(name: name, icon: icon, color: color, existing: existing)
        let runtime = buildRuntime(from: profile)
        runtimes.append(runtime)
        activeProfileId = runtime.id
        Task {
            applyAdBlockToTabs(in: runtime)
            await runtime.extensionHost.loadAllEnabledExtensions()
        }
        scheduleSave()
        showToast("Created \(runtime.name) profile", tone: .success)
        return runtime
    }

    func updateProfile(id: UUID, name: String, icon: String, color: BrowserProfileColor) {
        guard let runtime = runtimes.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { runtime.name = trimmed }
        if !icon.isEmpty { runtime.icon = icon }
        runtime.color = color
        scheduleSave()
    }

    func deleteProfile(id: UUID) {
        guard runtimes.count > 1, let idx = runtimes.firstIndex(where: { $0.id == id }) else { return }
        let removed = runtimes.remove(at: idx)
        for tab in removed.tabs {
            if tab.activeShare != nil {
                Task { await stopShare(for: tab, reason: "profile_deleted") }
            }
            tab.teardown()
        }
        removed.extensionHost.teardown()
        if activeProfileId == id {
            activeProfileId = runtimes[0].id
        }
        scheduleSave()
        showToast("Deleted \(removed.name) profile", tone: .neutral)
    }

    // MARK: Tab Lifecycle

    private func createSession(record: BrowserTabRecord, in runtime: BrowserProfileRuntime) -> BrowserTabSession {
        let session = BrowserTabSession(
            record: record,
            profileID: runtime.id,
            profileDataStoreID: runtime.dataStoreID,
            contentRuleLists: adBlockEngine.compiledRuleLists,
            adBlockPageScript: adBlockEngine.compiledPageScript,
            adBlockActive: isAdBlockActive(for: record.url, in: runtime),
            webExtensionController: runtime.extensionHost.controller,
            lockdownModeEnabled: isLockdownActive(for: record.url, in: runtime),
            proxyConfig: runtime.proxyConfig
        )
        session.adBlockActiveProvider = { [weak self, weak runtime] url in
            guard let self, let runtime else { return true }
            return self.isAdBlockActive(for: url, in: runtime)
        }
        session.securityConfigProvider = { [weak self] in
            self?.securityConfig ?? .default
        }
        session.httpsOnlyExceptionsProvider = { [weak runtime] in
            runtime?.httpsOnlyExceptions ?? []
        }
        session.lockdownActiveProvider = { [weak self, weak runtime] url in
            guard let self, let runtime else { return false }
            return self.isLockdownActive(for: url, in: runtime)
        }
        session.javascriptAllowedProvider = { [weak runtime] url in
            guard let runtime else { return true }
            return BrowserHTTPSGuard.isJavaScriptAllowed(for: url, disabledHosts: runtime.javascriptDisabledHosts)
        }
        session.sitePermissionProvider = { [weak runtime] host, kind in
            guard let runtime, let normalized = BrowserPageGuard.normalizeHost(host) else { return .ask }
            return runtime.sitePermissions[normalized]?[kind.rawValue] ?? .ask
        }
        session.onSitePermissionChanged = { [weak self, weak runtime] host, kind, setting in
            guard let self, let runtime else { return }
            self.setSitePermission(host: host, kind: kind, setting: setting, in: runtime)
        }
        session.neverShareProvider = { [weak self] in self?.extensionConfig.neverShare ?? BrowserNeverShareLists() }
        session.hostZoomProvider = { [weak runtime] host in
            guard let runtime, let normalized = BrowserPageGuard.normalizeHost(host) else { return nil }
            return runtime.siteZooms[normalized]
        }
        session.onOpenNewTab = { [weak self, weak runtime] url, isPrivate in
            guard let self, let runtime else { return }
            _ = self.newTab(url: url, isPrivate: isPrivate, select: true, in: runtime)
        }
        session.onPageCommitted = { [weak self] _ in
            self?.scheduleSave()
        }
        session.onPageFinished = { [weak self, weak runtime] tab in
            guard let self, let runtime else { return }
            if !tab.isPrivate, !tab.urlString.isEmpty {
                runtime.history = BrowserTabListLogic.recordVisit(
                    url: tab.urlString,
                    title: tab.displayTitle,
                    in: runtime.history
                )
            }
            self.scheduleSave()
        }
        session.onStateChanged = { [weak self] in
            self?.scheduleSave()
        }
        session.onTabShouldClose = { [weak self, weak runtime] tab in
            guard let self, let runtime else { return }
            self.closeTab(tab.id, in: runtime)
        }
        session.onSnapshotDue = { [weak self] tab in
            guard let self else { return }
            Task { await self.sendSnapshot(for: tab) }
        }
        session.onStopShare = { [weak self] tab, reason in
            guard let self else { return }
            Task { await self.stopShare(for: tab, reason: reason) }
        }
        session.onCredentialsSubmitted = { [weak self, weak runtime] tab, url, username, password in
            guard let self, let runtime else { return }
            if let pending = runtime.autofill.evaluateSubmission(
                urlString: url,
                username: username,
                password: password,
                isPrivate: tab.isPrivate,
                autofillEnabled: self.autofillEnabled,
                neverSaveHosts: runtime.autofillNeverSaveHosts
            ) {
                tab.pendingCredentialSave = pending
            }
        }
        session.onExtensionPropertiesChanged = { [weak runtime] tab, props in
            runtime?.extensionHost.notifyTabChanged(props, for: tab)
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
            onCaptureRegionScreenshot: { [weak self, weak session] in
                guard let self, let session else { return }
                self.beginRegionCapture(for: session)
            },
            onAutofillKeychain: { [weak self] in
                self?.triggerAutofillPopover()
            },
            onGeneratePassword: { [weak self, weak session] in
                guard let self, let session else { return }
                Task { await self.generateAndFillPassword(for: session) }
            },
            onOpenInSplitView: { [weak self, weak session] in
                guard let self, let session else { return }
                self.openInSplitView(tabId: session.id)
            },
            onOpenInSafari: { [weak session] in
                guard let session, let url = URL(string: session.urlString), BrowserURLResolver.isWebURL(url) else { return }
                NSWorkspace.shared.open(url)
            }
        )
        return session
    }

    @discardableResult
    func newTab(
        url: URL? = nil,
        isPrivate: Bool = false,
        select: Bool = true,
        groupId: UUID? = nil,
        in targetRuntime: BrowserProfileRuntime? = nil
    ) -> BrowserTabSession {
        let runtime = targetRuntime ?? currentRuntime
        let previous = runtime.tabs.first(where: { $0.id == runtime.activeTabId })
        let record = BrowserTabRecord(
            url: url?.absoluteString ?? "",
            title: isPrivate ? "Private Tab" : "New Tab",
            isPinned: false,
            isPrivate: isPrivate,
            groupId: isPrivate ? nil : groupId
        )
        let session = createSession(record: record, in: runtime)
        runtime.tabs.append(session)
        runtime.extensionHost.notifyTabOpened(session)
        if select {
            if runtime.focusedPane == .secondary, runtime.splitTabId != nil {
                runtime.splitTabId = session.id
            } else {
                runtime.activeTabId = session.id
                runtime.focusedPane = .primary
            }
            runtime.extensionHost.notifyTabActivated(session, previous: previous)
            if url == nil && runtime.id == activeProfileId {
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
        let runtime = currentRuntime
        if reuseExisting, !isPrivate, let existing = runtime.tabs.first(where: { !$0.isPrivate && $0.urlString == url.absoluteString }) {
            selectTab(existing.id)
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
        _ = newTab(url: url, isPrivate: isPrivate, select: true, in: runtime)
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
        let runtime = currentRuntime
        guard let next = runtime.tabs.first(where: { $0.id == id }) else { return }
        let previous = activeTab
        if runtime.splitTabId == id {
            runtime.focusedPane = .secondary
        } else {
            runtime.activeTabId = id
            runtime.focusedPane = .primary
        }
        if previous?.id != next.id {
            runtime.extensionHost.notifyTabActivated(next, previous: previous)
        }
        scheduleSave()
    }

    func selectNumberedTab(_ number: Int) {
        let ordered = orderedTabs
        guard let idx = BrowserTabListLogic.indexForNumberedShortcut(number, count: ordered.count) else { return }
        selectTab(ordered[idx].id)
    }

    func selectNextTab() {
        let ordered = orderedTabs
        let currentIdx = activeTab.flatMap { tab in ordered.firstIndex(where: { $0.id == tab.id }) }
        guard let next = BrowserTabListLogic.nextIndex(after: currentIdx, count: ordered.count) else { return }
        selectTab(ordered[next].id)
    }

    func selectPreviousTab() {
        let ordered = orderedTabs
        let currentIdx = activeTab.flatMap { tab in ordered.firstIndex(where: { $0.id == tab.id }) }
        guard let prev = BrowserTabListLogic.previousIndex(before: currentIdx, count: ordered.count) else { return }
        selectTab(ordered[prev].id)
    }

    func closeActiveTab() {
        guard let active = activeTab else { return }
        closeTab(active.id)
    }

    func closeTab(_ id: UUID, in targetRuntime: BrowserProfileRuntime? = nil) {
        let runtime = targetRuntime ?? currentRuntime
        let ordered = BrowserTabGroupLogic.displayOrder(
            tabs: runtime.tabs,
            groups: runtime.tabGroups,
            isPinned: \.isPinned,
            groupId: \.groupId
        )
        guard let rawIndex = runtime.tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = runtime.tabs.remove(at: rawIndex)
        if regionCaptureTabId == id { regionCaptureTabId = nil }
        if removed.activeShare != nil {
            Task { await stopShare(for: removed, reason: "tab_closed") }
        }
        if !removed.isPrivate, !removed.urlString.isEmpty {
            runtime.closedTabs.append(removed.record)
            if runtime.closedTabs.count > 20 { runtime.closedTabs.removeFirst(runtime.closedTabs.count - 20) }
        }
        runtime.extensionHost.notifyTabClosed(removed)
        removed.teardown()

        if runtime.tabs.isEmpty {
            let fresh = createSession(record: BrowserTabRecord(), in: runtime)
            runtime.tabs = [fresh]
            runtime.activeTabId = fresh.id
            runtime.splitTabId = nil
            runtime.focusedPane = .primary
            runtime.extensionHost.notifyTabOpened(fresh)
            if runtime.id == activeProfileId { focusAddressBarTick &+= 1 }
        } else {
            let splitBefore = BrowserSplitState(
                primaryTabId: runtime.activeTabId,
                secondaryTabId: runtime.splitTabId,
                ratio: runtime.splitRatio
            )
            if splitBefore.isSplit {
                let remainingIDs = runtime.tabs.map(\.id)
                let reconciled = BrowserTabGroupLogic.reconcileSplitAfterClose(
                    closedTabId: id,
                    state: splitBefore,
                    remainingTabIds: remainingIDs
                )
                runtime.activeTabId = reconciled.primaryTabId
                runtime.splitTabId = reconciled.secondaryTabId
                if runtime.splitTabId == nil { runtime.focusedPane = .primary }
            } else if runtime.activeTabId == id {
                let oldOrderedIdx = ordered.firstIndex(where: { $0.id == id }) ?? 0
                let nextOrdered = BrowserTabGroupLogic.displayOrder(
                    tabs: runtime.tabs,
                    groups: runtime.tabGroups,
                    isPinned: \.isPinned,
                    groupId: \.groupId
                )
                let targetIdx = min(oldOrderedIdx, max(0, nextOrdered.count - 1))
                runtime.activeTabId = nextOrdered[targetIdx].id
            }
        }
        scheduleSave()
    }

    func closeOtherTabs(keeping id: UUID) {
        let doomed = currentRuntime.tabs.filter { $0.id != id && !$0.isPinned }.map(\.id)
        for tabId in doomed {
            closeTab(tabId)
        }
    }

    func reopenClosedTab() {
        let runtime = currentRuntime
        guard let record = runtime.closedTabs.popLast() else { return }
        let validGroup = record.groupId.flatMap { gid in
            runtime.tabGroups.contains(where: { $0.id == gid }) ? gid : nil
        }
        let restored = BrowserTabRecord(
            id: UUID(),
            url: record.url,
            title: record.title,
            isPinned: false,
            isPrivate: false,
            zoom: record.zoom,
            groupId: validGroup,
            isMuted: record.isMuted
        )
        let session = createSession(record: restored, in: runtime)
        runtime.tabs.append(session)
        runtime.activeTabId = session.id
        runtime.focusedPane = .primary
        runtime.extensionHost.notifyTabOpened(session)
        scheduleSave()
    }

    func duplicateTab(_ id: UUID) {
        guard let source = currentRuntime.tabs.first(where: { $0.id == id }) else { return }
        _ = newTab(url: URL(string: source.urlString), isPrivate: source.isPrivate, select: true, groupId: source.groupId)
    }

    func togglePin(_ id: UUID) {
        guard let tab = currentRuntime.tabs.first(where: { $0.id == id }) else { return }
        tab.isPinned.toggle()
        if tab.isPinned { tab.groupId = nil }
        currentRuntime.extensionHost.notifyTabChanged([.pinned], for: tab)
        scheduleSave()
    }

    func toggleMute(_ id: UUID? = nil) {
        guard let tab = id.flatMap({ tid in currentRuntime.tabs.first(where: { $0.id == tid }) }) ?? activeTab else { return }
        tab.setMuted(!tab.isMuted)
    }

    func moveTab(_ sourceID: UUID, before targetID: UUID) {
        let runtime = currentRuntime
        guard let source = runtime.tabs.first(where: { $0.id == sourceID }),
              let target = runtime.tabs.first(where: { $0.id == targetID })
        else { return }
        // Match target's pin & group membership when dropped onto another tab row.
        source.isPinned = target.isPinned
        source.groupId = target.isPinned ? nil : target.groupId
        runtime.tabs = BrowserTabGroupLogic.move(sourceID, before: targetID, in: runtime.tabs)
        scheduleSave()
    }

    // MARK: Tab Groups

    @discardableResult
    func createTabGroup(name: String, color: BrowserProfileColor = .blue, initialTabId: UUID? = nil) -> BrowserTabGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = BrowserTabGroup(
            name: trimmed.isEmpty ? "Group \(currentRuntime.tabGroups.count + 1)" : trimmed,
            color: color
        )
        currentRuntime.tabGroups.append(group)
        if let initialTabId, let tab = currentRuntime.tabs.first(where: { $0.id == initialTabId }), !tab.isPrivate {
            tab.isPinned = false
            tab.groupId = group.id
        }
        scheduleSave()
        return group
    }

    func renameTabGroup(id: UUID, name: String, color: BrowserProfileColor) {
        guard let idx = currentRuntime.tabGroups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { currentRuntime.tabGroups[idx].name = trimmed }
        currentRuntime.tabGroups[idx].color = color
        scheduleSave()
    }

    func toggleTabGroupCollapsed(id: UUID) {
        guard let idx = currentRuntime.tabGroups.firstIndex(where: { $0.id == id }) else { return }
        currentRuntime.tabGroups[idx].isCollapsed.toggle()
        scheduleSave()
    }

    func assignTab(_ tabId: UUID, toGroup groupId: UUID?) {
        guard let tab = currentRuntime.tabs.first(where: { $0.id == tabId }) else { return }
        if tab.isPrivate && groupId != nil { return }
        if groupId != nil { tab.isPinned = false }
        tab.groupId = groupId
        scheduleSave()
    }

    func deleteTabGroup(id: UUID, closeTabs: Bool = false) {
        let memberIDs = currentRuntime.tabs.filter { $0.groupId == id }.map(\.id)
        currentRuntime.tabGroups.removeAll { $0.id == id }
        if closeTabs {
            for tid in memberIDs { closeTab(tid) }
        } else {
            for tab in currentRuntime.tabs where tab.groupId == id {
                tab.groupId = nil
            }
        }
        scheduleSave()
    }

    // MARK: Split View

    func toggleSplitView() {
        let runtime = currentRuntime
        if isSplitViewActive {
            closeSplitView()
            return
        }
        guard let primary = primaryTab else { return }
        // Prefer another existing open tab; otherwise open a fresh tab on the right.
        if let other = orderedTabs.first(where: { $0.id != primary.id }) {
            runtime.splitTabId = other.id
            runtime.focusedPane = .secondary
        } else {
            let right = newTab(url: nil, isPrivate: primary.isPrivate, select: false, in: runtime)
            runtime.splitTabId = right.id
            runtime.focusedPane = .secondary
            focusAddressBarTick &+= 1
        }
        scheduleSave()
    }

    func openInSplitView(tabId: UUID) {
        let runtime = currentRuntime
        guard runtime.tabs.contains(where: { $0.id == tabId }) else { return }
        if runtime.activeTabId == tabId {
            // If called on the already-primary tab, open a companion right pane.
            if !isSplitViewActive {
                toggleSplitView()
            }
            return
        }
        let next = BrowserTabGroupLogic.openInSplit(
            tabId: tabId,
            current: BrowserSplitState(primaryTabId: runtime.activeTabId, secondaryTabId: runtime.splitTabId, ratio: runtime.splitRatio)
        )
        runtime.activeTabId = next.primaryTabId
        runtime.splitTabId = next.secondaryTabId
        runtime.focusedPane = .secondary
        scheduleSave()
    }

    func closeSplitView() {
        let runtime = currentRuntime
        if runtime.focusedPane == .secondary, let sec = runtime.splitTabId {
            runtime.activeTabId = sec
        }
        runtime.splitTabId = nil
        runtime.focusedPane = .primary
        scheduleSave()
    }

    func swapSplitPanes() {
        let runtime = currentRuntime
        let current = BrowserSplitState(primaryTabId: runtime.activeTabId, secondaryTabId: runtime.splitTabId, ratio: runtime.splitRatio)
        guard current.isSplit else { return }
        let swapped = BrowserTabGroupLogic.swapPanes(current)
        runtime.activeTabId = swapped.primaryTabId
        runtime.splitTabId = swapped.secondaryTabId
        runtime.splitRatio = swapped.ratio
        runtime.focusedPane = runtime.focusedPane == .primary ? .secondary : .primary
        scheduleSave()
    }

    func focusSplitPane(_ pane: SplitPane) {
        let runtime = currentRuntime
        guard pane == .primary || isSplitViewActive else { return }
        let previous = activeTab
        runtime.focusedPane = pane
        if let now = activeTab, previous?.id != now.id {
            runtime.extensionHost.notifyTabActivated(now, previous: previous)
        }
    }

    func setSplitRatio(_ ratio: Double) {
        currentRuntime.splitRatio = min(0.8, max(0.2, ratio))
        scheduleSave()
    }

    // MARK: Triggers

    func focusAddressBar() {
        focusAddressBarTick &+= 1
    }

    func triggerAutofillPopover() {
        openAutofillPopoverTick &+= 1
    }

    func triggerExtensionsPopover() {
        openExtensionsPopoverTick &+= 1
    }

    func beginRegionCapture(for tab: BrowserTabSession? = nil) {
        guard let target = tab ?? activeTab, target.hasLoadedPage else {
            showToast("Open a web page first", tone: .error)
            return
        }
        regionCaptureTabId = target.id
    }

    func cancelRegionCapture() {
        regionCaptureTabId = nil
    }

    // MARK: AutoFill Actions

    func savePendingCredential(for tab: BrowserTabSession) {
        guard let pending = tab.pendingCredentialSave else { return }
        let ok = currentRuntime.autofill.saveCredential(
            host: pending.host,
            username: pending.username,
            password: pending.password,
            existingId: pending.existingCredentialId
        )
        tab.pendingCredentialSave = nil
        if ok {
            showToast(pending.isUpdate ? "Updated password for \(pending.host) in Keychain" : "Saved password for \(pending.host) to Keychain", tone: .success)
        } else {
            showToast(currentRuntime.autofill.lastError ?? "Couldn't save to Keychain", tone: .error)
        }
    }

    func dismissPendingCredential(for tab: BrowserTabSession) {
        tab.pendingCredentialSave = nil
    }

    func neverSavePasswords(for host: String, tab: BrowserTabSession?) {
        guard let normalized = BrowserPageGuard.normalizeHost(host) else { return }
        if !currentRuntime.autofillNeverSaveHosts.contains(normalized) {
            currentRuntime.autofillNeverSaveHosts.append(normalized)
            scheduleSave()
        }
        tab?.pendingCredentialSave = nil
        showToast("Won't offer to save passwords for \(normalized)", tone: .neutral)
    }

    func fillCredential(_ credential: BrowserCredential, into tab: BrowserTabSession? = nil) async {
        guard let target = tab ?? activeTab else { return }
        let ok = await currentRuntime.autofill.fill(
            credential,
            into: target.webView,
            requireTouchID: securityConfig.requireTouchIDForAutofill
        )
        if ok {
            showToast("Filled \(credential.username) from Keychain", tone: .success)
        } else if !BrowserAutofillLogic.canAutofill(
            urlString: target.urlString,
            hasOnlySecureContent: target.hasOnlySecureContent
        ) {
            showToast("AutoFill blocked on insecure or mixed-content page", tone: .error)
        } else {
            showToast("AutoFill cancelled or no matching login form found", tone: .neutral)
        }
    }

    func copyCredentialPassword(_ credential: BrowserCredential) async {
        let allowed = await currentRuntime.autofill.authenticateIfRequired(
            requireTouchID: securityConfig.requireTouchIDForAutofill,
            reason: "Copy saved password for \(credential.host)"
        )
        guard allowed else {
            showToast("Authentication required to copy password", tone: .error)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(credential.password, forType: .string)
        showToast("Copied password for \(credential.host)", tone: .neutral)
    }

    func importApplePasswordsCSV(from url: URL) {
        guard let csv = try? String(contentsOf: url, encoding: .utf8) else {
            showToast("Couldn't read CSV file", tone: .error)
            return
        }
        let count = currentRuntime.autofill.importApplePasswordsCSV(csv)
        if count > 0 {
            showToast("Imported \(count) login\(count == 1 ? "" : "s") into Keychain", tone: .success)
        } else {
            showToast("No valid logins found in CSV (expected Apple Passwords format)", tone: .neutral)
        }
    }

    // MARK: Security, Permissions & Per-Profile Proxy

    func isLockdownActive(for urlString: String, in runtime: BrowserProfileRuntime? = nil) -> Bool {
        let target = runtime ?? currentRuntime
        return BrowserHTTPSGuard.isLockdownActive(
            for: urlString,
            globalEnabled: securityConfig.lockdownModeEnabled,
            enabledHosts: target.lockdownEnabledHosts,
            disabledHosts: target.lockdownDisabledHosts
        )
    }

    func isJavaScriptAllowed(for urlString: String, in runtime: BrowserProfileRuntime? = nil) -> Bool {
        let target = runtime ?? currentRuntime
        return BrowserHTTPSGuard.isJavaScriptAllowed(
            for: urlString,
            disabledHosts: target.javascriptDisabledHosts
        )
    }

    func toggleLockdown(forHost rawHost: String) {
        guard let host = BrowserPageGuard.normalizeHost(rawHost) else { return }
        let runtime = currentRuntime
        if securityConfig.lockdownModeEnabled {
            if let idx = runtime.lockdownDisabledHosts.firstIndex(of: host) {
                runtime.lockdownDisabledHosts.remove(at: idx)
            } else {
                runtime.lockdownDisabledHosts.append(host)
            }
        } else {
            if let idx = runtime.lockdownEnabledHosts.firstIndex(of: host) {
                runtime.lockdownEnabledHosts.remove(at: idx)
            } else {
                runtime.lockdownEnabledHosts.append(host)
            }
        }
        scheduleSave()
        activeTab?.reload()
    }

    func toggleJavaScript(forHost rawHost: String) {
        guard let host = BrowserPageGuard.normalizeHost(rawHost) else { return }
        let runtime = currentRuntime
        if let idx = runtime.javascriptDisabledHosts.firstIndex(of: host) {
            runtime.javascriptDisabledHosts.remove(at: idx)
        } else {
            runtime.javascriptDisabledHosts.append(host)
        }
        scheduleSave()
        activeTab?.reload()
    }

    func allowHTTPFallback(for tab: BrowserTabSession) {
        guard let fallbackURL = tab.pendingHTTPSFallbackURL else { return }
        if let host = fallbackURL.host, let normalized = BrowserPageGuard.normalizeHost(host) {
            if !currentRuntime.httpsOnlyExceptions.contains(normalized) {
                currentRuntime.httpsOnlyExceptions.append(normalized)
                scheduleSave()
            }
        }
        tab.pendingHTTPSFallbackURL = nil
        tab.load(fallbackURL)
    }

    func sitePermission(forHost rawHost: String, kind: BrowserPermissionKind, in runtime: BrowserProfileRuntime? = nil) -> BrowserPermissionSetting {
        let target = runtime ?? currentRuntime
        guard let host = BrowserPageGuard.normalizeHost(rawHost) else { return .ask }
        return target.sitePermissions[host]?[kind.rawValue] ?? .ask
    }

    func setSitePermission(
        host rawHost: String,
        kind: BrowserPermissionKind,
        setting: BrowserPermissionSetting,
        in runtime: BrowserProfileRuntime? = nil
    ) {
        let target = runtime ?? currentRuntime
        guard let host = BrowserPageGuard.normalizeHost(rawHost) else { return }
        var map = target.sitePermissions[host] ?? [:]
        if setting == .ask {
            map.removeValue(forKey: kind.rawValue)
        } else {
            map[kind.rawValue] = setting
        }
        if map.isEmpty {
            target.sitePermissions.removeValue(forKey: host)
        } else {
            target.sitePermissions[host] = map
        }
        scheduleSave()
    }

    func updateProxyConfig(_ config: BrowserProxyConfig, for runtime: BrowserProfileRuntime? = nil) {
        let target = runtime ?? currentRuntime
        target.proxyConfig = config
        BrowserWebViewFactory.applyProxy(config, toProfileID: target.dataStoreID)
        scheduleSave()
        if config.isConfigured {
            showToast("Applied \(config.mode.label) proxy (\(config.host):\(config.port)) for \(target.name)", tone: .success)
        } else {
            showToast("Reset \(target.name) proxy to System Default", tone: .neutral)
        }
    }

    func generateAndFillPassword(for tab: BrowserTabSession? = nil, length: Int = 20, includeSymbols: Bool = true) async {
        let password = BrowserAutofillLogic.generateStrongPassword(length: length, includeSymbols: includeSymbols)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(password, forType: .string)
        if let target = tab ?? activeTab, target.hasLoadedPage {
            let filled = await currentRuntime.autofill.fillGeneratedPassword(password, into: target.webView)
            showToast(filled ? "Filled & copied strong password" : "Copied strong password to clipboard", tone: .success)
        } else {
            showToast("Copied strong password to clipboard", tone: .success)
        }
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
        guard let runtime = runtimes.first(where: { $0.id == tab.profileID }) else { return }
        if !tab.isPrivate, let host = BrowserPageGuard.normalizeHost(tab.urlString) {
            if abs(zoom - 1.0) < 0.01 {
                runtime.siteZooms.removeValue(forKey: host)
            } else {
                runtime.siteZooms[host] = zoom
            }
            scheduleSave()
        }
    }

    func isAdBlockActive(for urlString: String, in runtime: BrowserProfileRuntime? = nil) -> Bool {
        let target = runtime ?? currentRuntime
        return BrowserContentBlockerRules.isAdBlockActive(
            globalEnabled: adBlockEnabled,
            host: urlString,
            disabledHosts: target.adBlockDisabledHosts
        )
    }

    func setAdBlockEnabled(_ enabled: Bool) {
        adBlockEnabled = enabled
        scheduleSave()
        Task {
            await recompileAdBlockAndApply()
            activeTab?.reload()
        }
    }

    /// Instantly toggles ad-blocking for one host without recompiling any `WKContentRuleList`.
    func toggleAdBlock(forHost rawHost: String) {
        guard let host = BrowserPageGuard.normalizeHost(rawHost) else { return }
        let runtime = currentRuntime
        if let idx = runtime.adBlockDisabledHosts.firstIndex(of: host) {
            runtime.adBlockDisabledHosts.remove(at: idx)
        } else {
            runtime.adBlockDisabledHosts.append(host)
        }
        scheduleSave()
        applyAdBlockToTabs(in: runtime)
        activeTab?.reload()
    }

    func setAdBlockCategory(_ category: BrowserAdBlockCategory, enabled: Bool) {
        adBlockConfig.setCategory(category, enabled: enabled)
        scheduleSave()
        Task {
            await recompileAdBlockAndApply()
            activeTab?.reload()
        }
    }

    func setYouTubeAdShieldEnabled(_ enabled: Bool) {
        adBlockConfig.youtubeAdShieldEnabled = enabled
        scheduleSave()
        Task {
            await recompileAdBlockAndApply()
            if let tab = activeTab, tab.urlString.lowercased().contains("youtube.com") {
                tab.reload()
            }
        }
    }

    func setAdBlockAutoUpdateEnabled(_ enabled: Bool) {
        adBlockConfig.autoUpdateEnabled = enabled
        scheduleSave()
    }

    func setFilterListEnabled(id: String, enabled: Bool) {
        guard let idx = adBlockConfig.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        adBlockConfig.subscriptions[idx].isEnabled = enabled
        scheduleSave()
        Task {
            await recompileAdBlockAndApply()
        }
    }

    @discardableResult
    func addCustomFilterList(name: String, urlString: String, category: BrowserAdBlockCategory) -> String? {
        guard let validated = BrowserAdBlockConfig.validateSubscriptionURL(urlString) else {
            return "Filter list URL must be a valid https:// address."
        }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleanedName.isEmpty ? (validated.host ?? "Custom Filter List") : cleanedName
        if adBlockConfig.subscriptions.contains(where: { $0.url.caseInsensitiveCompare(validated.absoluteString) == .orderedSame }) {
            return "That filter list URL is already subscribed."
        }
        let sub = BrowserFilterListSubscription(
            name: title,
            category: category,
            url: validated.absoluteString,
            isBuiltIn: false,
            isEnabled: true
        )
        adBlockConfig.subscriptions.append(sub)
        scheduleSave()
        Task {
            await refreshAdBlockLists(silent: false)
        }
        return nil
    }

    func removeCustomFilterList(id: String) {
        guard let idx = adBlockConfig.subscriptions.firstIndex(where: { $0.id == id && !$0.isBuiltIn }) else { return }
        adBlockConfig.subscriptions.remove(at: idx)
        adBlockEngine.deleteCachedList(for: id)
        scheduleSave()
        Task {
            await recompileAdBlockAndApply(force: true)
        }
    }

    func updateCustomAdBlockRules(_ rules: String) {
        adBlockConfig.customRules = rules
        scheduleSave()
        Task {
            await recompileAdBlockAndApply()
            activeTab?.reload()
        }
    }

    func refreshAdBlockLists(silent: Bool = false) async {
        let result = await adBlockEngine.updateFilterLists(config: adBlockConfig)
        // Merge only subscription fetch metadata back into current `adBlockConfig` so concurrent
        // toggles, custom rules edits, or added/removed lists are never overwritten.
        let byID = Dictionary(uniqueKeysWithValues: result.config.subscriptions.map { ($0.id, $0) })
        for idx in adBlockConfig.subscriptions.indices {
            if let updated = byID[adBlockConfig.subscriptions[idx].id] {
                adBlockConfig.subscriptions[idx].lastUpdatedAt = updated.lastUpdatedAt
                adBlockConfig.subscriptions[idx].ruleCount = updated.ruleCount
                adBlockConfig.subscriptions[idx].lastError = updated.lastError
            }
        }
        if let ts = result.config.lastUpdatedAt {
            adBlockConfig.lastUpdatedAt = ts
        }
        scheduleSave()
        await recompileAdBlockAndApply(force: result.updatedCount > 0)
        if !silent {
            if result.errorCount == 0 && result.updatedCount > 0 {
                showToast("Updated \(result.updatedCount) filter list\(result.updatedCount == 1 ? "" : "s") (\(adBlockEngine.stats.totalActiveRules) rules)", tone: .success)
            } else if result.updatedCount > 0 {
                showToast("Updated \(result.updatedCount) lists (\(result.errorCount) failed)", tone: .neutral)
            } else if result.errorCount > 0 {
                showToast("Couldn't refresh filter lists (check network)", tone: .error)
            }
        }
    }

    func recompileAdBlockAndApply(force: Bool = false) async {
        await adBlockEngine.recompile(enabled: adBlockEnabled, config: adBlockConfig, force: force)
        for runtime in runtimes {
            applyAdBlockToTabs(in: runtime)
        }
    }

    private func applyAdBlockToTabs(in runtime: BrowserProfileRuntime) {
        let lists = adBlockEngine.compiledRuleLists
        let script = adBlockEngine.compiledPageScript
        for tab in runtime.tabs {
            let active = isAdBlockActive(for: tab.urlString, in: runtime)
            tab.applyAdBlockState(ruleLists: lists, pageScript: script, activeForCurrentURL: active)
        }
    }

    // MARK: Bookmarks & History

    var bookmarkFolders: [String] {
        let set = Set(currentRuntime.bookmarks.compactMap { bm -> String? in
            let trimmed = bm.folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        })
        return set.sorted()
    }

    func isBookmarked(_ urlString: String) -> Bool {
        guard !urlString.isEmpty else { return false }
        return currentRuntime.bookmarks.contains(where: { $0.url == urlString })
    }

    func toggleBookmark(for tab: BrowserTabSession? = nil, folder: String? = nil) {
        guard let tab = tab ?? activeTab, !tab.urlString.isEmpty else { return }
        let runtime = currentRuntime
        if let idx = runtime.bookmarks.firstIndex(where: { $0.url == tab.urlString }) {
            runtime.bookmarks.remove(at: idx)
            showToast("Removed bookmark", tone: .neutral)
        } else {
            let cleanFolder = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
            runtime.bookmarks.insert(
                BrowserBookmark(url: tab.urlString, title: tab.displayTitle, folder: cleanFolder?.isEmpty == true ? nil : cleanFolder),
                at: 0
            )
            showToast("Bookmarked \(tab.displayTitle)", tone: .success)
        }
        scheduleSave()
    }

    func updateBookmark(id: String, title: String, folder: String?) {
        guard let idx = currentRuntime.bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty { currentRuntime.bookmarks[idx].title = cleanTitle }
        let cleanFolder = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentRuntime.bookmarks[idx].folder = cleanFolder?.isEmpty == true ? nil : cleanFolder
        scheduleSave()
    }

    func removeBookmark(id: String) {
        currentRuntime.bookmarks.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearHistory() {
        currentRuntime.history.removeAll()
        scheduleSave()
    }

    func removeHistoryEntry(id: String) {
        currentRuntime.history.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearBrowsingData(for runtime: BrowserProfileRuntime? = nil) async {
        let target = runtime ?? currentRuntime
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let dataStore = BrowserWebViewFactory.store(forProfileID: target.dataStoreID)
        await dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
        showToast("Cleared cookies & cache for \(target.name)", tone: .neutral)
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
            let activeById = Dictionary(uniqueKeysWithValues: cfg.shares.map { ($0.id, $0) })
            for runtime in runtimes {
                for tab in runtime.tabs {
                    if let share = tab.activeShare {
                        if let updated = activeById[share.id] {
                            tab.activeShare = updated
                        } else {
                            tab.activeShare = nil
                            tab.shareStartURL = nil
                        }
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
            for runtime in runtimes {
                for tab in runtime.tabs where tab.activeShare != nil {
                    if !pageShareCheck(for: tab).ok {
                        tab.activeShare = nil
                        tab.shareStartURL = nil
                    }
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
        for runtime in runtimes {
            for tab in runtime.tabs {
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
        }
        if !anyActiveShare {
            sharePollTask?.cancel()
            sharePollTask = nil
        }
    }

    // MARK: Ask, Clip, Screenshot (Viewport & Region) & Quote Actions

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

    func screenshotToKnowledge(tab: BrowserTabSession, rect: CGRect? = nil, caption: String? = nil) async {
        guard let apiClient = app?.system.store.client else {
            showToast("Connect Vesper to save screenshots", tone: .error)
            return
        }
        guard tab.hasLoadedPage else {
            showToast("Open a web page first", tone: .error)
            return
        }
        guard let pngData = await tab.captureScreenshotPNG(rect: rect) else {
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

    func screenshotToChat(tab: BrowserTabSession, rect: CGRect? = nil) async {
        guard tab.hasLoadedPage else {
            showToast("Open a web page first", tone: .error)
            return
        }
        guard let pngData = await tab.captureScreenshotPNG(rect: rect) else {
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

    func copyScreenshot(tab: BrowserTabSession, rect: CGRect? = nil) async {
        guard tab.hasLoadedPage, let pngData = await tab.captureScreenshotPNG(rect: rect), let image = NSImage(data: pngData) else {
            showToast("Couldn't capture page screenshot", tone: .error)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        showToast(rect == nil ? "Copied page screenshot" : "Copied region screenshot", tone: .neutral)
    }

    func completeRegionCapture(tab: BrowserTabSession, rect: CGRect, destination: BrowserRegionCaptureDestination) async {
        regionCaptureTabId = nil
        switch destination {
        case .knowledge:
            await screenshotToKnowledge(tab: tab, rect: rect)
        case .chat:
            await screenshotToChat(tab: tab, rect: rect)
        case .clipboard:
            await copyScreenshot(tab: tab, rect: rect)
        }
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

    func showToast(
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
