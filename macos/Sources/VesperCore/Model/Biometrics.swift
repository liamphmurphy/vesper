import Foundation

// Port of desktop/src/biometrics.ts: the decision half of optional Touch ID before approving.
// This is a local gate only; the server never sees or verifies it. The prompt itself
// (LocalAuthentication) lives in the app and fails closed.

public enum TouchIdDecision: Equatable, Sendable { case prompt, skip }

public enum Biometrics {
    /// Whether an approval in `scope` needs Touch ID. `.skip` when the setting is off, the scope is
    /// off, or the Mac can't prompt (no sensor, clamshell, not enrolled).
    public static func touchIdDecision(_ settings: NativeSettings.TouchId, scope: String?, canPrompt: Bool) -> TouchIdDecision {
        guard settings.enabled, canPrompt, let scope, let s = TouchIdScope(rawValue: scope) else { return .skip }
        return settings.isOn(s) ? .prompt : .skip
    }

    public static func touchIdDecision(_ settings: NativeSettings.TouchId, scope: TouchIdScope, canPrompt: Bool) -> TouchIdDecision {
        touchIdDecision(settings, scope: scope.rawValue, canPrompt: canPrompt)
    }

    /// The text macOS shows under "Vesper is trying to …".
    public static func touchIdReason(_ scope: TouchIdScope) -> String {
        switch scope {
        case .runApprovals: return "approve an agent's request"
        case .pushRequests: return "approve a push and pull request"
        case .connectorApprovals: return "allow a connector tool call"
        case .secretApprovals: return "allow a request that uses a secret"
        }
    }
}
