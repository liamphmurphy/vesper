import LocalAuthentication
import VesperCore

/// Touch ID through LocalAuthentication (desktop/src/biometrics.ts + native.ts `confirmTouchId`). A
/// local gate only: the server never sees it. A prompt that fails or is cancelled refuses.
@MainActor
enum TouchID {
    /// Whether this Mac can show a Touch ID prompt now (sensor present, enrolled, lid open).
    static func canPrompt() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    static func authenticate(reason: String, passwordFallback: Bool = false) async -> Bool {
        let context = LAContext()
        let policy: LAPolicy = passwordFallback ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics
        if !passwordFallback { context.localizedFallbackTitle = "" }
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            vlog("touch id not confirmed: \(error.localizedDescription)")
            return false
        }
    }

    /// Prompts when `settings` ask for it in `scope`. true = go ahead (not needed, or confirmed).
    static func confirm(_ settings: NativeSettings.TouchId, scope: TouchIdScope?) async -> Bool {
        guard settings.enabled else { return true }
        // A scope this build doesn't know: if the gate is on, it still has to pass.
        let decision = Biometrics.touchIdDecision(settings, scope: scope?.rawValue, canPrompt: canPrompt())
        let reason = scope.map(Biometrics.touchIdReason) ?? "approve a request"
        switch decision {
        case .skip: return true
        case .prompt: return await authenticate(reason: reason)
        case .promptWithPassword: return await authenticate(reason: reason, passwordFallback: true)
        }
    }
}
