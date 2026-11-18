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

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            vlog("touch id not confirmed: \(error.localizedDescription)")
            return false
        }
    }

    /// Prompts when `settings` ask for it in `scope`. true = go ahead (not needed, or confirmed).
    static func confirm(_ settings: NativeSettings.TouchId, scope: TouchIdScope?) async -> Bool {
        guard settings.enabled else { return true }
        guard let scope else {
            // A scope this build doesn't know: if the gate is on, it still has to pass.
            return canPrompt() ? await authenticate(reason: "approve a request") : true
        }
        guard Biometrics.touchIdDecision(settings, scope: scope, canPrompt: canPrompt()) == .prompt else { return true }
        return await authenticate(reason: Biometrics.touchIdReason(scope))
    }
}
