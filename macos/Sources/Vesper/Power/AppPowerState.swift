import AppKit
import Observation
import SwiftUI
import VesperCore

/// App-wide foreground, hidden, and Low Power Mode state used to gate idle animations and timers.
@MainActor
@Observable
final class AppPowerState {
    static let shared = AppPowerState()

    private(set) var isActive: Bool
    private(set) var isHidden: Bool
    private(set) var isLowPowerMode: Bool

    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    private init() {
        self.isActive = NSApp?.isActive ?? true
        self.isHidden = NSApp?.isHidden ?? false
        self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isActive = true }
        })
        tokens.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isActive = false }
        })
        tokens.append(center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isHidden = true }
        })
        tokens.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isHidden = false }
        })
        tokens.append(center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        })
    }

    func animationContext(reduceMotion: Bool, windowVisible: Bool) -> AnimationPolicy.Context {
        AnimationPolicy.Context(
            reduceMotion: reduceMotion,
            windowVisible: windowVisible && !isHidden,
            appActive: isActive,
            lowPowerMode: isLowPowerMode
        )
    }
}

/// Tracks whether a hosted SwiftUI root is attached to a non-hidden, non-minimized, unoccluded
/// AppKit window. Automatically turns `false` for detached background tabs, hidden/collapsed
/// inspector panes, occluded or minimized windows, and closed windows with `isReleasedWhenClosed = false`.
@MainActor
@Observable
private final class HostVisibilityState {
    var isVisible = false
}

private final class VisibilityProbeNSView: NSView {
    var onChange: ((Bool) -> Void)?
    private var windowTokens: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebindWindowObservers()
        refresh()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refresh()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func teardown() {
        removeWindowObservers()
        onChange = nil
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for token in windowTokens { center.removeObserver(token) }
        windowTokens.removeAll()
        observedWindow = nil
    }

    private func rebindWindowObservers() {
        guard observedWindow !== window else { return }
        removeWindowObservers()
        observedWindow = window
        guard let window else { return }

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        for name in names {
            windowTokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        windowTokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(false) }
        })
    }

    func refresh() {
        guard let window else {
            report(false)
            return
        }
        let visible = !isHiddenOrHasHiddenAncestor
            && window.isVisible
            && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        report(visible)
    }

    private func report(_ visible: Bool) {
        guard lastReported != visible else { return }
        lastReported = visible
        let handler = onChange
        // Defer outside AppKit/SwiftUI view update passes.
        Task { @MainActor in
            handler?(visible)
        }
    }
}

private struct HostVisibilityProbe: NSViewRepresentable {
    let state: HostVisibilityState

    func makeNSView(context: Context) -> VisibilityProbeNSView {
        let view = VisibilityProbeNSView()
        view.onChange = { [weak state] visible in
            if state?.isVisible != visible {
                state?.isVisible = visible
            }
        }
        return view
    }

    func updateNSView(_ nsView: VisibilityProbeNSView, context: Context) {
        nsView.onChange = { [weak state] visible in
            if state?.isVisible != visible {
                state?.isVisible = visible
            }
        }
        nsView.refresh()
    }

    static func dismantleNSView(_ nsView: VisibilityProbeNSView, coordinator: ()) {
        nsView.teardown()
    }
}

private struct HostVisibilityModifier: ViewModifier {
    @State private var visibility = HostVisibilityState()

    func body(content: Content) -> some View {
        content
            .background(HostVisibilityProbe(state: visibility).allowsHitTesting(false))
            .environment(\.vesperWindowVisible, visibility.isVisible)
    }
}

extension View {
    /// Tracks whether this view's AppKit host is visible on screen and publishes it via `\.vesperWindowVisible`.
    func vesperTrackHostVisibility() -> some View {
        modifier(HostVisibilityModifier())
    }
}
