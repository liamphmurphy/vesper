import AppKit
import Foundation
import Observation
import VesperCore

/// App-wide observable source for the native macOS right rail: polls and observes `QueryStore`
/// (`github/review-requests`, `secrets`) alongside `RailInbox`, and owns local GitHub review
/// filter and dismissal state.
@MainActor
@Observable
final class NativeRailStore {
    private static let prefsKey = "VesperNativePRReviewFilters"
    private static let dismissedKey = "VesperNativePRReviewDismissed"
    private static let reviewsPollInterval: Duration = .seconds(300)
    private static let reviewsStaleAfter: TimeInterval = 120

    private static let reviewRequestsRequest = API.listGitHubReviewRequests()
    private static let secretsRequest = API.listSecrets()

    @ObservationIgnored private let store: QueryStore
    @ObservationIgnored private let railInbox: RailInbox
    @ObservationIgnored private var reviewPollTask: Task<Void, Never>?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private var lastReviewsFetch = Date.distantPast
    @ObservationIgnored private var observingQueries = false

    private(set) var isConnected = false
    private(set) var reviewPrefs: RailLogic.ReviewFilterPrefs
    private(set) var dismissedReviews: [String: String]

    init(store: QueryStore, railInbox: RailInbox) {
        self.store = store
        self.railInbox = railInbox
        self.reviewPrefs = RailLogic.parseReviewFilterPrefs(UserDefaults.standard.string(forKey: Self.prefsKey))
        self.dismissedReviews = RailLogic.parseDismissedReviews(UserDefaults.standard.string(forKey: Self.dismissedKey))
    }

    func start() {
        stop()
        isConnected = true
        store.observe(Self.reviewRequestsRequest)
        store.observe(Self.secretsRequest)
        observingQueries = true
        store.load(Self.reviewRequestsRequest)
        store.load(Self.secretsRequest)
        lastReviewsFetch = Date()

        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isConnected,
                      Date().timeIntervalSince(self.lastReviewsFetch) >= Self.reviewsStaleAfter else { return }
                self.lastReviewsFetch = Date()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.store.refetch(Self.reviewRequestsRequest)
                }
            }
        }

        reviewPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.reviewsPollInterval)
                guard !Task.isCancelled, let self else { return }
                guard AppPowerState.shared.isActive else { continue }
                self.lastReviewsFetch = Date()
                _ = await self.store.refetch(Self.reviewRequestsRequest)
            }
        }
    }

    func stop() {
        reviewPollTask?.cancel()
        reviewPollTask = nil
        if let observer = activeObserver {
            NotificationCenter.default.removeObserver(observer)
            activeObserver = nil
        }
        if observingQueries {
            store.stopObserving(Self.reviewRequestsRequest.key)
            store.stopObserving(Self.secretsRequest.key)
            observingQueries = false
        }
        isConnected = false
    }

    /// Builds the `RailModel` for `tab`, or `nil` while disconnected or showing a playground tab.
    func model(for tab: WebContentController?, poppedOut: Bool) -> RailModel? {
        guard isConnected, let tab, tab.kind == .vesper else { return nil }
        let inspector = tab.state.inspector
        let top = RailLogic.effectiveRailTop(
            nativeActive: tab.state.native != nil,
            inspector: inspector,
            poppedOut: poppedOut,
            pageRailTop: tab.state.rail?.top
        )
        let pathname = tab.state.route ?? tab.pendingPath
        let reviewsData = store.entry(Self.reviewRequestsRequest).data
        let secretsData = store.entry(Self.secretsRequest).data

        let needsYou = railInbox.tray.needs.count
        let approved = railInbox.items.reduce(0) { partial, item in
            partial + (item.kind == "pr_approved" && InboxTray.isOpen(item) ? 1 : 0)
        }
        let review = RailLogic.buildReviewInput(
            response: reviewsData,
            dismissed: dismissedReviews,
            prefs: reviewPrefs,
            approved: approved
        )
        let settingsNeedYou = RailLogic.settingsNeedAttention(secretsData)

        return RailLogic.buildModel(
            dock: top,
            pathname: pathname,
            review: review,
            needsYou: needsYou,
            settingsNeedYou: settingsNeedYou
        )
    }

    // MARK: - Review actions

    func reviewURL(for id: String) -> String? {
        store.entry(Self.reviewRequestsRequest).data?.items.first { $0.id == id }?.url
    }

    func refreshReviews() {
        lastReviewsFetch = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let client = self.store.client,
               let fresh = try? await client.send(API.listGitHubReviewRequests(refresh: true)) {
                self.store.setData(fresh, for: Self.reviewRequestsRequest)
            } else {
                _ = await self.store.refetch(Self.reviewRequestsRequest)
            }
        }
    }

    func toggleReviewPref(_ key: RailLogic.ReviewPrefKey) {
        var next = reviewPrefs
        switch key {
        case .direct: next.direct.toggle()
        case .team: next.team.toggle()
        }
        reviewPrefs = next
        if let encoded = RailLogic.encodeReviewFilterPrefs(next) {
            UserDefaults.standard.set(encoded, forKey: Self.prefsKey)
        }
    }

    func dismissReview(id: String) {
        guard let item = store.entry(Self.reviewRequestsRequest).data?.items.first(where: { $0.id == id }) else { return }
        saveDismissed(RailLogic.dismiss([item], in: dismissedReviews))
    }

    func clearVisibleReviews() {
        let all = store.entry(Self.reviewRequestsRequest).data?.items ?? []
        let visible = RailLogic.filterReviews(RailLogic.excludeDismissed(all, dismissed: dismissedReviews), prefs: reviewPrefs)
        guard !visible.isEmpty else { return }
        saveDismissed(RailLogic.dismiss(visible, in: dismissedReviews))
    }

    func restoreDismissedReviews() {
        let all = store.entry(Self.reviewRequestsRequest).data?.items ?? []
        let hidden = RailLogic.filterReviews(all, prefs: reviewPrefs).filter { RailLogic.isDismissed($0, in: dismissedReviews) }
        guard !hidden.isEmpty else { return }
        saveDismissed(RailLogic.restore(hidden, from: dismissedReviews))
    }

    private func saveDismissed(_ next: [String: String]) {
        guard next != dismissedReviews else { return }
        dismissedReviews = next
        if let encoded = RailLogic.encodeDismissedReviews(next) {
            UserDefaults.standard.set(encoded, forKey: Self.dismissedKey)
        }
    }
}
