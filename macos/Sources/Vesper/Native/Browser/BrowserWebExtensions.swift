import AppKit
import Foundation
import Observation
import VesperCore
import WebKit

// MARK: - Toolbar Snapshot Model

struct BrowserExtensionToolbarItem: Identifiable {
    let id: UUID
    let displayName: String
    let version: String
    let description: String
    let sourcePath: String
    let isEnabled: Bool
    let isLoaded: Bool
    let allowInPrivate: Bool
    let hasOptionsPage: Bool
    let actionLabel: String
    let badgeText: String
    let actionEnabled: Bool
    let presentsPopup: Bool
    let icon: NSImage?
    let requestedPermissions: [String]
    let grantedPermissions: [String]
    let requestedHosts: [String]
    let grantedHosts: [String]
    let errors: [String]
}

// MARK: - WKWebExtensionTab / WKWebExtensionWindow Adapters

/// Exposes one `BrowserTabSession` to WebKit's `WKWebExtensionController`.
@MainActor
final class BrowserExtensionTabAdapter: NSObject, WKWebExtensionTab {
    weak var session: BrowserTabSession?
    weak var host: BrowserExtensionHost?

    init(session: BrowserTabSession, host: BrowserExtensionHost) {
        self.session = session
        self.host = host
        super.init()
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        host?.windowAdapter
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let session, let tabs = host?.tabsProvider?() else { return NSNotFound }
        return tabs.firstIndex(where: { $0.id == session.id }) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard let session else { return nil }
        if session.isPrivate && !context.hasAccessToPrivateData {
            return nil
        }
        return session.webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        session?.displayTitle
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        session?.isPinned ?? false
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let session {
            host?.onSetPinned?(session.id, pinned)
        }
        completionHandler(nil)
    }

    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool {
        session?.hasLoadedPage ?? false
    }

    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool {
        session?.isReaderMode ?? false
    }

    func setReaderModeActive(_ active: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let session else { completionHandler(nil); return }
        if session.isReaderMode != active {
            Task { @MainActor in
                await session.toggleReaderMode(darkMode: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                completionHandler(nil)
            }
        } else {
            completionHandler(nil)
        }
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        session?.isAudioPlaying ?? false
    }

    func isMuted(for context: WKWebExtensionContext) -> Bool {
        session?.isMuted ?? false
    }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let session {
            session.setMuted(muted)
        }
        completionHandler(nil)
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        session?.webView.bounds.size ?? CGSize(width: 1024, height: 768)
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        session?.zoom ?? 1.0
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        session?.setZoom(zoomFactor)
        completionHandler(nil)
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        guard let raw = session?.urlString, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard let session, session.isLoading, !session.urlString.isEmpty else { return nil }
        return URL(string: session.urlString)
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(session?.isLoading ?? false)
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping (NSImage?, Error?) -> Void) {
        guard let webView = session?.webView else {
            completionHandler(nil, nil)
            return
        }
        webView.takeSnapshot(with: configuration) { image, error in
            completionHandler(image, error)
        }
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        session?.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        session?.reload(fromOrigin: fromOrigin)
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        session?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        session?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let session {
            host?.onActivateTab?(session.id)
        }
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let session else { return false }
        return host?.activeTabProvider?()?.id == session.id
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if selected, let session {
            host?.onActivateTab?(session.id)
        }
        completionHandler(nil)
    }

    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        guard let session, let newTab = host?.onDuplicateTab?(session.id, configuration.shouldBeActive) else {
            completionHandler(nil, nil)
            return
        }
        completionHandler(host?.tabAdapter(for: newTab), nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let session {
            host?.onCloseTab?(session.id)
        }
        completionHandler(nil)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }
}

/// Exposes the Vesper Browser surface as a `WKWebExtensionWindow` for one profile.
@MainActor
final class BrowserExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    weak var host: BrowserExtensionHost?

    init(host: BrowserExtensionHost) {
        self.host = host
        super.init()
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let host, let tabs = host.tabsProvider?() else { return [] }
        return tabs
            .filter { !$0.isPrivate || context.hasAccessToPrivateData }
            .map { host.tabAdapter(for: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let host, let active = host.activeTabProvider?() else { return nil }
        if active.isPrivate && !context.hasAccessToPrivateData { return nil }
        return host.tabAdapter(for: active)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = host?.hostWindowProvider?() else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        host?.activeTabProvider?()?.isPrivate ?? false
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        host?.hostWindowProvider?()?.screen?.frame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        host?.hostWindowProvider?()?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 840)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        host?.hostWindowProvider?()?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}

// MARK: - Profile-Scoped WKWebExtensionController Host

/// Hosts WebExtensions (`WKWebExtensionController`) for a single browser profile, isolating
/// extension storage and website data stores per profile.
@MainActor
@Observable
final class BrowserExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    let profileID: UUID
    let dataStoreID: UUID
    let controller: WKWebExtensionController

    private(set) var records: [BrowserExtensionRecord] = []
    private(set) var toolbarItems: [BrowserExtensionToolbarItem] = []
    private(set) var lastError: String?

    /// Anchor view registered by the omnibox toolbar so `action.popupPopover` opens cleanly beneath it.
    @ObservationIgnored weak var popupAnchorView: NSView?
    @ObservationIgnored var tabsProvider: (() -> [BrowserTabSession])?
    @ObservationIgnored var activeTabProvider: (() -> BrowserTabSession?)?
    @ObservationIgnored var hostWindowProvider: (() -> NSWindow?)?
    @ObservationIgnored var onOpenTab: ((URL?, Bool, Bool) -> BrowserTabSession?)?
    @ObservationIgnored var onActivateTab: ((UUID) -> Void)?
    @ObservationIgnored var onCloseTab: ((UUID) -> Void)?
    @ObservationIgnored var onDuplicateTab: ((UUID, Bool) -> BrowserTabSession?)?
    @ObservationIgnored var onSetPinned: ((UUID, Bool) -> Void)?
    @ObservationIgnored var onRecordsChanged: (([BrowserExtensionRecord]) -> Void)?

    @ObservationIgnored private var loadedContexts: [UUID: WKWebExtensionContext] = [:]
    @ObservationIgnored private var loadErrors: [UUID: String] = [:]
    @ObservationIgnored private var tabAdapters: [UUID: BrowserExtensionTabAdapter] = [:]
    @ObservationIgnored private let managedRootDir: URL
    @ObservationIgnored fileprivate var windowAdapter: BrowserExtensionWindowAdapter?

    init(profileID: UUID, dataStoreID: UUID, dataDirectory: URL, initialRecords: [BrowserExtensionRecord]) {
        self.profileID = profileID
        self.dataStoreID = dataStoreID
        self.managedRootDir = BrowserStorage.extensionsDirectory(dataDirectory: dataDirectory)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        self.records = initialRecords

        let config = WKWebExtensionController.Configuration(identifier: dataStoreID)
        config.defaultWebsiteDataStore = BrowserWebViewFactory.store(forProfileID: dataStoreID)
        self.controller = WKWebExtensionController(configuration: config)

        super.init()
        let winAdapter = BrowserExtensionWindowAdapter(host: self)
        self.windowAdapter = winAdapter
        self.controller.delegate = self
        self.controller.didOpenWindow(winAdapter)
        rebuildToolbarItems()
    }

    func loadAllEnabledExtensions() async {
        for record in records where record.isEnabled {
            await loadExtension(record: record)
        }
        rebuildToolbarItems()
    }

    func tabAdapter(for session: BrowserTabSession) -> BrowserExtensionTabAdapter {
        if let existing = tabAdapters[session.id], existing.session === session {
            return existing
        }
        let adapter = BrowserExtensionTabAdapter(session: session, host: self)
        tabAdapters[session.id] = adapter
        return adapter
    }

    // MARK: Tab Lifecycle Forwarding to WKWebExtensionController

    func notifyTabOpened(_ session: BrowserTabSession) {
        let adapter = tabAdapter(for: session)
        controller.didOpenTab(adapter)
        rebuildToolbarItems()
    }

    func notifyTabClosed(_ session: BrowserTabSession) {
        if let adapter = tabAdapters.removeValue(forKey: session.id) {
            controller.didCloseTab(adapter, windowIsClosing: false)
        }
        rebuildToolbarItems()
    }

    func notifyTabActivated(_ session: BrowserTabSession, previous: BrowserTabSession?) {
        let currentAdapter = tabAdapter(for: session)
        let prevAdapter = previous.map { tabAdapter(for: $0) }
        controller.didActivateTab(currentAdapter, previousActiveTab: prevAdapter)
        rebuildToolbarItems()
    }

    func notifyTabChanged(_ properties: WKWebExtension.TabChangedProperties, for session: BrowserTabSession) {
        let adapter = tabAdapter(for: session)
        controller.didChangeTabProperties(properties, for: adapter)
        if properties.contains(.URL) || properties.contains(.loading) {
            rebuildToolbarItems()
        }
    }

    // MARK: Install / Toggle / Permissions / Uninstall

    /// Installs a WebExtension from an unpacked folder, `.zip` archive, or `.appex` bundle.
    @discardableResult
    func installExtension(from sourceURL: URL, copyIntoManagedStorage: Bool = false) async -> Result<BrowserExtensionRecord, Error> {
        do {
            let extID = UUID()
            var finalURL = sourceURL
            var isManaged = false

            if copyIntoManagedStorage {
                try FileManager.default.createDirectory(at: managedRootDir, withIntermediateDirectories: true)
                let dest = managedRootDir.appendingPathComponent("\(extID.uuidString.lowercased())-\(sourceURL.lastPathComponent)")
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: sourceURL, to: dest)
                finalURL = dest
                isManaged = true
            }

            let wkExt = try await instantiateWebExtension(at: finalURL)
            let displayName = wkExt.displayName ?? wkExt.displayShortName ?? finalURL.deletingPathExtension().lastPathComponent
            let record = BrowserExtensionRecord(
                id: extID,
                displayName: displayName,
                identifier: extID.uuidString.lowercased(),
                sourcePath: finalURL.path,
                isEnabled: true,
                isManagedCopy: isManaged,
                allowInPrivate: false,
                grantAllHosts: true
            )

            try loadContext(for: wkExt, record: record)
            records.append(record)
            lastError = nil
            onRecordsChanged?(records)
            rebuildToolbarItems()
            return .success(record)
        } catch {
            lastError = error.localizedDescription
            vlog("browser extension install failed: \(error)")
            return .failure(error)
        }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) async {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].isEnabled = enabled
        if enabled {
            await loadExtension(record: records[idx])
        } else {
            unloadExtension(id: id)
        }
        onRecordsChanged?(records)
        rebuildToolbarItems()
    }

    func setAllowInPrivate(_ allowed: Bool, for id: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].allowInPrivate = allowed
        if let ctx = loadedContexts[id] {
            ctx.hasAccessToPrivateData = allowed
        }
        onRecordsChanged?(records)
        rebuildToolbarItems()
    }

    func grantAllRequestedAccess(for id: UUID) {
        guard let ctx = loadedContexts[id] else { return }
        grantRequestedPermissions(on: ctx, includeHosts: true)
        if let idx = records.firstIndex(where: { $0.id == id }) {
            records[idx].grantAllHosts = true
            onRecordsChanged?(records)
        }
        rebuildToolbarItems()
    }

    func revokeAllHostAccess(for id: UUID) {
        guard let ctx = loadedContexts[id] else { return }
        for pattern in ctx.currentPermissionMatchPatterns {
            ctx.setPermissionStatus(.unknown, for: pattern)
        }
        if let idx = records.firstIndex(where: { $0.id == id }) {
            records[idx].grantAllHosts = false
            onRecordsChanged?(records)
        }
        rebuildToolbarItems()
    }

    func performAction(for id: UUID) {
        guard let ctx = loadedContexts[id] else { return }
        let activeTab = activeTabProvider?().map { tabAdapter(for: $0) }
        if let activeTab {
            ctx.userGesturePerformed(in: activeTab)
        }
        ctx.performAction(for: activeTab)
        rebuildToolbarItems()
    }

    func openOptionsPage(for id: UUID) {
        guard let ctx = loadedContexts[id], let url = ctx.optionsPageURL else { return }
        _ = onOpenTab?(url, false, true)
    }

    func removeExtension(id: UUID) {
        unloadExtension(id: id)
        if let idx = records.firstIndex(where: { $0.id == id }) {
            let rec = records.remove(at: idx)
            if rec.isManagedCopy, !rec.sourcePath.isEmpty {
                try? FileManager.default.removeItem(atPath: rec.sourcePath)
            }
        }
        loadErrors.removeValue(forKey: id)
        onRecordsChanged?(records)
        rebuildToolbarItems()
    }

    func teardown() {
        for (_, ctx) in loadedContexts {
            try? controller.unload(ctx)
        }
        loadedContexts.removeAll()
        tabAdapters.removeAll()
        if let win = windowAdapter {
            controller.didCloseWindow(win)
        }
    }

    // MARK: Internal Loading

    private func loadExtension(record: BrowserExtensionRecord) async {
        guard loadedContexts[record.id] == nil else { return }
        let url = URL(fileURLWithPath: record.sourcePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadErrors[record.id] = "Extension files not found at \(url.lastPathComponent)."
            return
        }
        do {
            let wkExt = try await instantiateWebExtension(at: url)
            try loadContext(for: wkExt, record: record)
            loadErrors.removeValue(forKey: record.id)
        } catch {
            loadErrors[record.id] = error.localizedDescription
            vlog("browser extension load failed (\(record.displayName)): \(error)")
        }
    }

    private func instantiateWebExtension(at url: URL) async throws -> WKWebExtension {
        if url.pathExtension.lowercased() == "appex", let bundle = Bundle(url: url) {
            return try await WKWebExtension(appExtensionBundle: bundle)
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            _ = try BrowserExtensionLogic.validateUnpackedDirectory(url)
        }
        return try await WKWebExtension(resourceBaseURL: url)
    }

    private func loadContext(for wkExt: WKWebExtension, record: BrowserExtensionRecord) throws {
        let ctx = WKWebExtensionContext(for: wkExt)
        ctx.uniqueIdentifier = record.identifier
        ctx.isInspectable = true
        ctx.hasAccessToPrivateData = record.allowInPrivate
        grantRequestedPermissions(on: ctx, includeHosts: record.grantAllHosts)
        try controller.load(ctx)
        loadedContexts[record.id] = ctx
    }

    private func grantRequestedPermissions(on ctx: WKWebExtensionContext, includeHosts: Bool) {
        let ext = ctx.webExtension
        for perm in ext.requestedPermissions {
            ctx.setPermissionStatus(.grantedExplicitly, for: perm)
        }
        if includeHosts {
            for pattern in ext.requestedPermissionMatchPatterns {
                ctx.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            for pattern in ext.allRequestedMatchPatterns {
                ctx.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
        }
    }

    private func unloadExtension(id: UUID) {
        guard let ctx = loadedContexts.removeValue(forKey: id) else { return }
        try? controller.unload(ctx)
    }

    func rebuildToolbarItems() {
        let activeAdapter = activeTabProvider?().map { tabAdapter(for: $0) }
        toolbarItems = records.map { rec in
            let ctx = loadedContexts[rec.id]
            let ext = ctx?.webExtension
            let action = ctx?.action(for: activeAdapter)
            let icon = action?.icon(for: CGSize(width: 18, height: 18))
                ?? ext?.actionIcon(for: CGSize(width: 18, height: 18))
                ?? ext?.icon(for: CGSize(width: 18, height: 18))

            var errs: [String] = []
            if let loadErr = loadErrors[rec.id] { errs.append(loadErr) }
            if let ctx {
                errs.append(contentsOf: ctx.errors.map(\.localizedDescription))
            }

            return BrowserExtensionToolbarItem(
                id: rec.id,
                displayName: ext?.displayName ?? rec.displayName,
                version: ext?.displayVersion ?? ext?.version ?? "",
                description: ext?.displayDescription ?? "",
                sourcePath: rec.sourcePath,
                isEnabled: rec.isEnabled,
                isLoaded: ctx?.isLoaded ?? false,
                allowInPrivate: rec.allowInPrivate,
                hasOptionsPage: ctx?.optionsPageURL != nil,
                actionLabel: action?.label ?? ext?.displayActionLabel ?? rec.displayName,
                badgeText: action?.badgeText ?? "",
                actionEnabled: action?.isEnabled ?? (ctx?.isLoaded ?? false),
                presentsPopup: action?.presentsPopup ?? false,
                icon: icon,
                requestedPermissions: ext?.requestedPermissions.map(\.rawValue).sorted() ?? [],
                grantedPermissions: ctx?.currentPermissions.map(\.rawValue).sorted() ?? [],
                requestedHosts: ext?.allRequestedMatchPatterns.map(\.string).sorted() ?? [],
                grantedHosts: ctx?.currentPermissionMatchPatterns.map(\.string).sorted() ?? [],
                errors: errs
            )
        }
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        windowAdapter.map { [$0] } ?? []
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        windowAdapter
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        let isPrivate = configuration.window?.isPrivate?(for: extensionContext) ?? false
        guard let session = onOpenTab?(configuration.url, isPrivate, configuration.shouldBeActive) else {
            completionHandler(nil, nil)
            return
        }
        if configuration.shouldBePinned {
            onSetPinned?(session.id, true)
        }
        if configuration.shouldBeMuted {
            session.setMuted(true)
        }
        completionHandler(tabAdapter(for: session), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        if let url = extensionContext.optionsPageURL {
            _ = onOpenTab?(url, false, true)
        }
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        rebuildToolbarItems()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let popover = action.popupPopover else {
            completionHandler(nil)
            return
        }
        let anchor = popupAnchorView ?? hostWindowProvider?()?.contentView
        guard let anchor else {
            completionHandler(nil)
            return
        }
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let name = extensionContext.webExtension.displayName ?? "Extension"
        let list = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Allow \"\(name)\" to use additional permissions?"
        alert.informativeText = list.isEmpty ? "The extension requested permissions." : "Requested: \(list)"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        Task { @MainActor in
            let response = await self.presentAlert(alert)
            completionHandler(response == .alertFirstButtonReturn ? permissions : [], nil)
            self.rebuildToolbarItems()
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let name = extensionContext.webExtension.displayName ?? "Extension"
        let hosts = urls.compactMap(\.host).sorted().joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Allow \"\(name)\" to access these sites?"
        alert.informativeText = hosts.isEmpty ? "The extension requested site access." : hosts
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        Task { @MainActor in
            let response = await self.presentAlert(alert)
            completionHandler(response == .alertFirstButtonReturn ? urls : [], nil)
            self.rebuildToolbarItems()
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let name = extensionContext.webExtension.displayName ?? "Extension"
        let patterns = matchPatterns.map(\.string).sorted().joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Allow \"\(name)\" to read and modify websites?"
        alert.informativeText = patterns.isEmpty ? "The extension requested host access." : patterns
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        Task { @MainActor in
            let response = await self.presentAlert(alert)
            completionHandler(response == .alertFirstButtonReturn ? matchPatterns : [], nil)
            self.rebuildToolbarItems()
        }
    }

    private func presentAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = hostWindowProvider?() {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}
