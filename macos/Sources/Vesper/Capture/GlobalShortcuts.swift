import Carbon.HIToolbox
import Foundation
import VesperCore

/// The three global shortcuts (Quick Capture, Screenshot to Chat, Show/Hide Vesper), registered
/// with Carbon's RegisterEventHotKey (no Accessibility permission needed). `apply` re-registers
/// everything and returns, per shortcut, why it couldn't be (shown in Settings).
@MainActor
final class GlobalShortcuts {
    enum Kind: String, CaseIterable {
        case quickCapture, screenshot, showHide
        var title: String {
            switch self {
            case .quickCapture: return "Quick Capture"
            case .screenshot: return "Screenshot to Chat"
            case .showHide: return "Show/Hide Vesper"
            }
        }
        var hotKeyID: UInt32 {
            switch self {
            case .quickCapture: return 1
            case .screenshot: return 2
            case .showHide: return 3
            }
        }
    }

    private var refs: [Kind: EventHotKeyRef] = [:]
    private var handlers: [Kind: () -> Void] = [:]
    private static let signature: OSType = 0x56535052 // 'VSPR'
    private var eventHandler: EventHandlerRef?
    /// Set false in tests/scratch runs to skip the system registration.
    var enabledBySystem = ProcessInfo.processInfo.environment["VESPER_NO_GLOBAL_SHORTCUTS"] != "1"

    func setHandler(_ kind: Kind, _ handler: @escaping () -> Void) { handlers[kind] = handler }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let raw = id.id
            let box = Unmanaged<GlobalShortcuts>.fromOpaque(userData)
            DispatchQueue.main.async { MainActor.assumeIsolated { box.takeUnretainedValue().fire(raw) } }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    private func fire(_ id: UInt32) {
        guard let kind = Kind.allCases.first(where: { $0.hotKeyID == id }) else { return }
        handlers[kind]?()
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
    }

    /// Registers every enabled shortcut. The result maps a kind to the reason it isn't active.
    @discardableResult
    func apply(_ settings: NativeSettings) -> [Kind: String] {
        unregisterAll()
        var errors: [Kind: String] = [:]
        var taken: [String: String] = [:] // accelerator -> owner title
        let config: [(Kind, NativeSettings.Shortcut)] = [
            (.quickCapture, settings.quickCapture), (.screenshot, settings.screenshot), (.showHide, settings.showHide),
        ]
        for (kind, cfg) in config where cfg.enabled {
            switch Self.check(cfg.shortcut, taken: taken) {
            case .failure(let e):
                errors[kind] = e.message
                continue
            case .success(let accelerator):
                taken[accelerator] = kind.title
                guard enabledBySystem else { continue }
                if let message = register(kind, accelerator: accelerator) { errors[kind] = message }
            }
        }
        return errors
    }

    /// Validation shared by Settings and registration: the accelerator is well formed, no other
    /// Vesper shortcut uses it and no system feature owns it.
    static func check(_ raw: String, taken: [String: String] = [:]) -> Result<String, CaptureError> {
        switch Capture.validateGlobalShortcut(raw) {
        case .failure(let e): return .failure(e)
        case .success(let acc):
            let label = Capture.formatAccelerator(acc)
            if let ours = taken[acc] { return .failure(CaptureError("\(ours) already uses \(label). Pick another shortcut.")) }
            if let owner = Capture.systemShortcutConflict(acc) { return .failure(CaptureError("\(label) belongs to \(owner). Pick another shortcut.")) }
            guard GlobalShortcut.binding(for: acc) != nil else { return .failure(CaptureError("\(label) can't be used as a global shortcut.")) }
            return .success(acc)
        }
    }

    private func register(_ kind: Kind, accelerator: String) -> String? {
        guard let binding = GlobalShortcut.binding(for: accelerator) else { return "That shortcut isn't valid." }
        installEventHandlerIfNeeded()
        let label = Capture.formatAccelerator(accelerator)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: Self.signature, id: kind.hotKeyID),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[kind] = ref
            return nil
        }
        if status == OSStatus(eventHotKeyExistsErr) || status == OSStatus(eventHotKeyInvalidErr) {
            return "\(label) is already in use. Pick another shortcut."
        }
        return "\(label) couldn't be registered (error \(status)). Pick another shortcut."
    }
}
