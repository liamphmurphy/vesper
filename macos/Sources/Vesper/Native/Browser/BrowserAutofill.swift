import AppKit
import Foundation
import LocalAuthentication
import Observation
import Security
import VesperCore
import WebKit

// MARK: - Biometric Gate (Touch ID / macOS Owner Auth + Test Double)

@MainActor
protocol BrowserBiometricAuthenticator: AnyObject {
    func authenticate(reason: String) async -> Bool
}

@MainActor
final class LocalAuthenticationBiometricAuthenticator: BrowserBiometricAuthenticator {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

// MARK: - Credential Store Protocol (Keychain + In-Memory Test Double)

@MainActor
protocol BrowserCredentialStore: AnyObject {
    func loadAll(profileID: UUID) -> [BrowserCredential]
    func save(_ credential: BrowserCredential, profileID: UUID) throws
    func delete(id: String, profileID: UUID) throws
}

enum BrowserCredentialStoreError: Error, LocalizedError {
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainFailure(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(message) (\(status))"
            }
            return "Keychain error (\(status))"
        }
    }
}

/// Stores per-profile browser credentials strictly in the macOS login Keychain under
/// `com.vesper.mac.browser.autofill.<profileID>`, never in `browser.json` or plain disk files.
@MainActor
final class KeychainBrowserCredentialStore: BrowserCredentialStore {
    private static func serviceName(for profileID: UUID) -> String {
        "com.vesper.mac.browser.autofill.\(profileID.uuidString.lowercased())"
    }

    func loadAll(profileID: UUID) -> [BrowserCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName(for: profileID),
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [BrowserCredential] = []
        for row in rows {
            guard let data = row[kSecValueData as String] as? Data,
                  let cred = try? decoder.decode(BrowserCredential.self, from: data)
            else { continue }
            out.append(cred)
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ credential: BrowserCredential, profileID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(credential)
        let service = Self.serviceName(for: profileID)

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.id,
        ]
        let attrs: [String: Any] = [
            kSecAttrLabel as String: "Vesper Browser (\(credential.host))",
            kSecAttrDescription as String: credential.username,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw BrowserCredentialStoreError.keychainFailure(updateStatus)
        }

        var addQuery = lookup
        for (k, v) in attrs { addQuery[k] = v }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BrowserCredentialStoreError.keychainFailure(addStatus)
        }
    }

    func delete(id: String, profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName(for: profileID),
            kSecAttrAccount as String: id,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BrowserCredentialStoreError.keychainFailure(status)
        }
    }
}

/// In-memory credential store used by automated tests so Keychain prompts never fire in CI/VM runs.
@MainActor
final class InMemoryBrowserCredentialStore: BrowserCredentialStore {
    private var storage: [UUID: [BrowserCredential]] = [:]

    func loadAll(profileID: UUID) -> [BrowserCredential] {
        (storage[profileID] ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ credential: BrowserCredential, profileID: UUID) throws {
        var list = storage[profileID] ?? []
        if let idx = list.firstIndex(where: { $0.id == credential.id }) {
            list[idx] = credential
        } else {
            list.append(credential)
        }
        storage[profileID] = list
    }

    func delete(id: String, profileID: UUID) throws {
        storage[profileID]?.removeAll { $0.id == id }
    }
}

// MARK: - Isolated AutoFill User Scripts (.defaultClient Content World)

enum BrowserAutofillScripts {
    static let messageHandlerName = "vesperAutofill"

    /// Runs in `WKContentWorld.defaultClient` so page JavaScript cannot intercept or tamper with
    /// the detector bridge. Reports when a login form exists and when a user submits credentials.
    static let detectorScriptSource = """
    (() => {
      if (window.__vesperAutofillInstalled) return;
      window.__vesperAutofillInstalled = true;

      const post = (payload) => {
        try {
          window.webkit?.messageHandlers?.vesperAutofill?.postMessage(payload);
        } catch (_) {}
      };

      const isVisible = (el) => {
        if (!el || el.disabled || el.type === "hidden") return false;
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      };

      const findUsernameInput = (root, passwordInput) => {
        const scope = root || document;
        const candidates = Array.from(scope.querySelectorAll(
          'input[autocomplete="username"], input[type="email"], input[type="text"], input:not([type])'
        )).filter(isVisible);
        if (!candidates.length) return null;
        const preferred = candidates.find((el) => {
          const hint = ((el.name || "") + " " + (el.id || "") + " " + (el.placeholder || "") + " " + (el.autocomplete || "")).toLowerCase();
          return /user|email|login|account|id/.test(hint);
        });
        if (preferred) return preferred;
        if (passwordInput) {
          const preceding = candidates.filter((el) => (el.compareDocumentPosition(passwordInput) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0);
          if (preceding.length) return preceding[preceding.length - 1];
        }
        return candidates[0];
      };

      const scanForms = () => {
        const pwInputs = Array.from(document.querySelectorAll('input[type="password"]')).filter(isVisible);
        post({ type: "formState", hasLoginForm: pwInputs.length > 0 });
      };

      const reportSubmission = (form) => {
        const root = form || document;
        const pw = Array.from(root.querySelectorAll('input[type="password"]')).find((el) => el.value && el.value.length > 0);
        if (!pw) return;
        const userEl = findUsernameInput(root, pw);
        const username = userEl ? String(userEl.value || "").trim() : "";
        const password = String(pw.value || "");
        if (!username || !password) return;
        post({
          type: "credentialsSubmitted",
          url: location.href,
          username: username.slice(0, 256),
          password: password.slice(0, 512)
        });
      };

      document.addEventListener("submit", (e) => {
        reportSubmission(e.target instanceof HTMLFormElement ? e.target : null);
      }, true);

      // Catch SPA logins that submit via button click without a native form submit event.
      document.addEventListener("click", (e) => {
        const btn = e.target && e.target.closest ? e.target.closest('button, input[type="submit"]') : null;
        if (!btn) return;
        const form = btn.closest("form");
        if (form || document.querySelector('input[type="password"]')) {
          reportSubmission(form);
        }
      }, true);

      const mo = new MutationObserver(() => {
        clearTimeout(window.__vesperAfTimer);
        window.__vesperAfTimer = setTimeout(scanForms, 300);
      });
      if (document.documentElement) {
        mo.observe(document.documentElement, { childList: true, subtree: true });
      }
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", scanForms, { once: true });
      } else {
        scanForms();
      }
    })();
    """

    /// Fills matching username & password inputs using native value setters + input/change events
    /// so React, Vue, Svelte, and vanilla forms all register the filled values.
    /// Guards against cross-origin iframe injection by refusing to run outside the top frame.
    static let fillCredentialFunctionBody = """
    if (window !== window.top) return false;
    const setNativeValue = (el, value) => {
      const proto = Object.getPrototypeOf(el);
      const desc = Object.getOwnPropertyDescriptor(proto, "value") || Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value");
      if (desc && desc.set) {
        desc.set.call(el, value);
      } else {
        el.value = value;
      }
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    };
    const isVisible = (el) => {
      if (!el || el.disabled || el.type === "hidden") return false;
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };
    const pwInputs = Array.from(document.querySelectorAll('input[type="password"]')).filter(isVisible);
    const pw = pwInputs[0] || null;
    const scope = pw && pw.form ? pw.form : document;
    const userCandidates = Array.from(scope.querySelectorAll(
      'input[autocomplete="username"], input[type="email"], input[type="text"], input:not([type])'
    )).filter(isVisible);
    let userEl = userCandidates.find((el) => {
      const hint = ((el.name || "") + " " + (el.id || "") + " " + (el.placeholder || "") + " " + (el.autocomplete || "")).toLowerCase();
      return /user|email|login|account|id/.test(hint);
    }) || userCandidates[0] || null;

    let filled = false;
    if (userEl && username) {
      userEl.focus();
      setNativeValue(userEl, username);
      filled = true;
    }
    if (pw && password) {
      pw.focus();
      setNativeValue(pw, password);
      filled = true;
    }
    return filled;
    """

    static let fillGeneratedPasswordFunctionBody = """
    const setNativeValue = (el, value) => {
      const proto = Object.getPrototypeOf(el);
      const desc = Object.getOwnPropertyDescriptor(proto, "value") || Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value");
      if (desc && desc.set) { desc.set.call(el, value); } else { el.value = value; }
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    };
    const active = document.activeElement;
    if (active && active.tagName === "INPUT" && (active.type === "password" || active.type === "text")) {
      setNativeValue(active, password);
      return true;
    }
    const pwInputs = Array.from(document.querySelectorAll('input[type="password"]')).filter((el) => {
      const r = el.getBoundingClientRect();
      return !el.disabled && r.width > 0 && r.height > 0;
    });
    if (!pwInputs.length) return false;
    for (const pw of pwInputs.slice(0, 2)) {
      setNativeValue(pw, password);
    }
    return true;
    """
}

// MARK: - Profile-Scoped AutoFill Manager

@MainActor
@Observable
final class BrowserAutofillManager {
    let profileID: UUID
    private(set) var credentials: [BrowserCredential] = []
    private(set) var lastError: String?

    @ObservationIgnored private let store: any BrowserCredentialStore
    @ObservationIgnored private let authenticator: any BrowserBiometricAuthenticator

    init(
        profileID: UUID,
        store: any BrowserCredentialStore = KeychainBrowserCredentialStore(),
        authenticator: any BrowserBiometricAuthenticator = LocalAuthenticationBiometricAuthenticator()
    ) {
        self.profileID = profileID
        self.store = store
        self.authenticator = authenticator
        reload()
    }

    func authenticateIfRequired(requireTouchID: Bool, reason: String) async -> Bool {
        guard requireTouchID else { return true }
        return await authenticator.authenticate(reason: reason)
    }

    @discardableResult
    func importApplePasswordsCSV(_ csv: String) -> Int {
        let parsed = BrowserAutofillLogic.parseApplePasswordsCSV(csv)
        var imported = 0
        for cred in parsed {
            if saveCredential(host: cred.host, username: cred.username, password: cred.password) {
                imported += 1
            }
        }
        return imported
    }

    func reload() {
        credentials = store.loadAll(profileID: profileID)
    }

    func matchingCredentials(for urlString: String) -> [BrowserCredential] {
        BrowserAutofillLogic.matchingCredentials(for: urlString, in: credentials)
    }

    @discardableResult
    func saveCredential(host rawHost: String, username: String, password: String, existingId: String? = nil) -> Bool {
        guard let host = BrowserPageGuard.normalizeHost(rawHost) else { return false }
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !password.isEmpty else { return false }

        let id = existingId ?? credentials.first(where: {
            BrowserPageGuard.normalizeHost($0.host) == host && $0.username.caseInsensitiveCompare(cleanUser) == .orderedSame
        })?.id ?? UUID().uuidString.lowercased()

        let cred = BrowserCredential(
            id: id,
            host: host,
            username: cleanUser,
            password: password,
            label: host,
            updatedAt: Date()
        )
        do {
            try store.save(cred, profileID: profileID)
            lastError = nil
            reload()
            return true
        } catch {
            lastError = error.localizedDescription
            vlog("browser autofill keychain save failed: \(error)")
            return false
        }
    }

    @discardableResult
    func deleteCredential(id: String) -> Bool {
        do {
            try store.delete(id: id, profileID: profileID)
            lastError = nil
            reload()
            return true
        } catch {
            lastError = error.localizedDescription
            vlog("browser autofill keychain delete failed: \(error)")
            return false
        }
    }

    /// Evaluates whether a submitted form should trigger a save/update banner on `tab`.
    func evaluateSubmission(
        urlString: String,
        username: String,
        password: String,
        isPrivate: Bool,
        autofillEnabled: Bool,
        neverSaveHosts: [String]
    ) -> BrowserPendingCredentialSave? {
        BrowserAutofillLogic.evaluateSavePrompt(
            urlString: urlString,
            username: username,
            password: password,
            isPrivate: isPrivate,
            autofillEnabled: autofillEnabled,
            neverSaveHosts: neverSaveHosts,
            existing: credentials
        )
    }

    /// Fills `credential` into the active `WKWebView` inside the isolated `.defaultClient` world.
    /// Blocks mixed-content HTTPS pages (`hasOnlySecureContent == false`) and optionally gates on Touch ID.
    func fill(
        _ credential: BrowserCredential,
        into webView: WKWebView,
        requireTouchID: Bool = false
    ) async -> Bool {
        guard let currentURL = webView.url?.absoluteString,
              BrowserAutofillLogic.canAutofill(
                  urlString: currentURL,
                  hasOnlySecureContent: webView.hasOnlySecureContent
              )
        else { return false }
        let allowed = BrowserAutofillLogic.matchingCredentials(for: currentURL, in: [credential])
        guard !allowed.isEmpty else { return false }
        guard await authenticateIfRequired(
            requireTouchID: requireTouchID,
            reason: "Fill saved password for \(credential.host)"
        ) else {
            return false
        }
        let result = try? await webView.callAsyncJavaScript(
            BrowserAutofillScripts.fillCredentialFunctionBody,
            arguments: ["username": credential.username, "password": credential.password],
            in: nil,
            contentWorld: .defaultClient
        )
        return (result as? Bool) ?? false
    }

    /// Injects a freshly generated strong password into the focused or first visible password input.
    func fillGeneratedPassword(_ password: String, into webView: WKWebView) async -> Bool {
        let result = try? await webView.callAsyncJavaScript(
            BrowserAutofillScripts.fillGeneratedPasswordFunctionBody,
            arguments: ["password": password],
            in: nil,
            contentWorld: .defaultClient
        )
        return (result as? Bool) ?? false
    }
}
