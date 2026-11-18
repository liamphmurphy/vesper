import Foundation

// Port of desktop/src/biometrics.ts: the decision half of optional Touch ID before approving.
// This is a local gate only; the server never sees or verifies it. The prompt itself
// (LocalAuthentication) lives in the app and fails closed.

public enum TouchIdDecision: Equatable, Sendable {
    /// Touch ID (biometrics).
    case prompt
    /// The gate is on but biometrics can't prompt: ask for the account password instead.
    case promptWithPassword
    case skip
}

public enum Biometrics {
    /// Whether an approval in `scope` needs Touch ID. `.skip` when the setting or the scope is off.
    /// When the gate is on (or the scope is unknown) but the Mac can't prompt (no sensor, clamshell,
    /// not enrolled), the account password is required instead.
    public static func touchIdDecision(_ settings: NativeSettings.TouchId, scope: String?, canPrompt: Bool) -> TouchIdDecision {
        guard settings.enabled else { return .skip }
        if let scope, let s = TouchIdScope(rawValue: scope), !settings.isOn(s) { return .skip }
        return canPrompt ? .prompt : .promptWithPassword
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
