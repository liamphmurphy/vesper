import Foundation
import XCTest
@testable import VesperCore

final class HttpClientLogicTests: XCTestCase {
    // MARK: - JSON Decoding & Encoding

    func testWorkspaceBundleDecodesServerPayloadWithNullArrays() throws {
        let json = """
        {
          "workspace": {
            "id": "ws-1",
            "name": "Billing API",
            "description": "",
            "active_environment_id": null,
            "default_auth": { "type": "bearer", "token": "{{api_token}}" },
            "default_headers": null,
            "default_vars": null,
            "created_at": "2026-11-22T00:00:00Z",
            "updated_at": "2026-11-22T00:00:00Z"
          },
          "environments": [
            {
              "id": "env-1",
              "http_workspace_id": "ws-1",
              "name": "nonprod",
              "color": "green",
              "variables": [
                { "key": "base_url", "value": "https://api.nonprod.example.com", "enabled": true },
                { "key": "api_token", "value": "", "secret_handle": "billing-key", "enabled": true }
              ],
              "sort_order": 0,
              "created_at": "2026-11-22T00:00:00Z",
              "updated_at": "2026-11-22T00:00:00Z"
            }
          ],
          "folders": null,
          "requests": [
            {
              "id": "req-1",
              "http_workspace_id": "ws-1",
              "folder_id": null,
              "name": "List Invoices",
              "method": "GET",
              "url": "{{base_url}}/v1/invoices",
              "params": null,
              "headers": null,
              "auth": { "type": "inherit", "api_key_in": "" },
              "body_mode": "none",
              "body": "",
              "body_form": null,
              "timeout_ms": 30000,
              "follow_redirects": true,
              "sort_order": 0,
              "created_at": "2026-11-22T00:00:00Z",
              "updated_at": "2026-11-22T00:00:00Z"
            }
          ]
        }
        """

        let bundle = try JSONDecoder().decode(HttpWorkspaceBundle.self, from: Data(json.utf8))
        XCTAssertEqual(bundle.workspace.id, "ws-1")
        XCTAssertNil(bundle.workspace.activeEnvironmentId)
        XCTAssertEqual(bundle.workspace.defaultAuth.type, .bearer)
        XCTAssertEqual(bundle.workspace.defaultAuth.token, "{{api_token}}")
        XCTAssertEqual(bundle.workspace.defaultHeaders, [])
        XCTAssertEqual(bundle.workspace.defaultVars, [])
        XCTAssertEqual(bundle.environments.count, 1)
        XCTAssertEqual(bundle.environments[0].variables[1].secretHandle, "billing-key")
        XCTAssertEqual(bundle.folders, [])
        XCTAssertEqual(bundle.requests.count, 1)
        XCTAssertNil(bundle.requests[0].auth.apiKeyIn)
        XCTAssertEqual(bundle.requests[0].bodyMode, .none)
    }

    func testExecutionNormalizesEmptyErrorAndOAuthDefaults() throws {
        let json = """
        {
          "id": "ex-1",
          "http_workspace_id": "ws-1",
          "request_id": "req-1",
          "environment_id": "env-1",
          "environment_name": "nonprod",
          "method": "POST",
          "resolved_url": "https://api.example.com/v1/items",
          "request_headers": { "Authorization": "Bearer [REDACTED]" },
          "request_body": "{}",
          "status_code": 201,
          "status_text": "201 Created",
          "duration_ms": 142,
          "size_bytes": 24,
          "response_headers": { "Content-Type": ["application/json; charset=utf-8"] },
          "response_body": "{\\"id\\":\\"123\\"}",
          "response_truncated": false,
          "error": "",
          "created_at": "2026-11-22T00:00:00Z"
        }
        """

        let exec = try JSONDecoder().decode(HttpExecution.self, from: Data(json.utf8))
        XCTAssertNil(exec.error)
        XCTAssertEqual(exec.statusCode, 201)
        XCTAssertEqual(exec.responseHeaders["Content-Type"], ["application/json; charset=utf-8"])

        let oauth = try JSONDecoder().decode(HttpOAuth2Config.self, from: Data("{}".utf8))
        XCTAssertEqual(oauth.grantType, "client_credentials")
        XCTAssertEqual(oauth.tokenUrl, "")
    }

    func testImportResultAndNullablePatchEncoding() throws {
        let resJson = """
        {
          "folders_created": 2,
          "requests_created": 5,
          "environments_created": 1,
          "warnings": null
        }
        """
        let res = try JSONDecoder().decode(HttpImportResult.self, from: Data(resJson.utf8))
        XCTAssertEqual(res, HttpImportResult(foldersCreated: 2, requestsCreated: 5, environmentsCreated: 1, warnings: []))

        let clearPatch = HttpActiveEnvironmentPatch(environmentId: nil)
        let data = try JSONEncoder().encode(clearPatch)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(raw["environment_id"] is NSNull)
    }

    // MARK: - API Builders & Invalidation

    func testEndpointBuildersAndInvalidations() {
        let wsReq = HttpClientAPI.listWorkspaces()
        XCTAssertEqual(wsReq.method, "GET")
        XCTAssertEqual(wsReq.pathAndQuery, "/api/v1/http/workspaces")

        let execsReq = HttpClientAPI.listRequestExecutions(requestId: "a/b", limit: 25)
        XCTAssertEqual(execsReq.pathAndQuery, "/api/v1/http/requests/a%2Fb/executions?limit=25")

        let bundleReq = HttpClientAPI.getWorkspaceBundle(id: "ws-1")
        let wsInv = HttpClientAPI.workspacesInvalidation
        let bundleInv = HttpClientAPI.bundleInvalidation(workspaceId: "ws-1")
        let otherBundleInv = HttpClientAPI.bundleInvalidation(workspaceId: "ws-2")

        XCTAssertTrue(wsInv.matches(wsReq.key))
        XCTAssertTrue(bundleInv.matches(bundleReq.key))
        XCTAssertFalse(otherBundleInv.matches(bundleReq.key))
        XCTAssertTrue(HttpClientAPI.executionsInvalidation(requestId: "req-1").matches(
            HttpClientAPI.listRequestExecutions(requestId: "req-1").key
        ))
        XCTAssertFalse(HttpClientAPI.executionsInvalidation(requestId: "req-1").matches(
            HttpClientAPI.listRequestExecutions(requestId: "req-2").key
        ))
    }

    func testLiveUpdatesIncludesHttpEntityAsQuiet() {
        XCTAssertEqual(LiveUpdates.invalidatedRoots("http.updated"), ["http"])
        let inv = LiveUpdates.invalidation(for: ServerEvent(type: "http.updated"))
        XCTAssertTrue(inv.matches(HttpClientAPI.listWorkspaces().key))
        XCTAssertTrue(inv.matches(HttpClientAPI.getWorkspaceBundle(id: "ws-1").key))
    }

    // MARK: - Drafts, Formatting & Status

    func testDraftConversionDirtyAndTimeouts() {
        let req = HttpRequest(
            id: "r1",
            httpWorkspaceId: "w1",
            folderId: "f1",
            name: "Get Users",
            method: "GET",
            url: "https://api.example.com/users",
            params: [HttpKeyValue(key: "limit", value: "10", enabled: true)],
            headers: [],
            auth: .inherit,
            bodyMode: .none,
            body: "",
            bodyForm: [],
            timeoutMs: 30000,
            followRedirects: true,
            sortOrder: 0
        )

        var draft = HttpClientLogic.toDraft(req)
        XCTAssertFalse(HttpClientLogic.isDirty(draft, comparedTo: req))
        draft.url = "https://api.example.com/v2/users"
        XCTAssertTrue(HttpClientLogic.isDirty(draft, comparedTo: req))

        XCTAssertEqual(HttpClientLogic.clampTimeoutMs(0), 30000)
        XCTAssertEqual(HttpClientLogic.clampTimeoutMs(10), 100)
        XCTAssertEqual(HttpClientLogic.clampTimeoutMs(999_999), 120_000)
        XCTAssertEqual(HttpClientLogic.runTimeoutSeconds(timeoutMs: 30_000), 45.0, accuracy: 0.01)
        XCTAssertEqual(HttpClientLogic.runTimeoutSeconds(timeoutMs: 5_000), 30.0, accuracy: 0.01)
    }

    func testMethodAndStatusFormattingHelpers() {
        XCTAssertEqual(HttpClientLogic.shortMethodLabel("DELETE"), "DEL")
        XCTAssertEqual(HttpClientLogic.shortMethodLabel("options"), "OPT")
        XCTAssertEqual(HttpClientLogic.shortMethodLabel("post"), "POST")

        XCTAssertEqual(HttpClientLogic.methodTone("GET"), .done)
        XCTAssertEqual(HttpClientLogic.methodTone("POST"), .accent)
        XCTAssertEqual(HttpClientLogic.methodTone("PATCH"), .human)
        XCTAssertEqual(HttpClientLogic.methodTone("DELETE"), .blocked)
        XCTAssertEqual(HttpClientLogic.methodTone("HEAD"), .neutral)

        XCTAssertEqual(HttpClientLogic.formatBytes(512), "512 B")
        XCTAssertEqual(HttpClientLogic.formatBytes(1536), "1.5 KB")
        XCTAssertEqual(HttpClientLogic.formatBytes(2 * 1024 * 1024), "2.00 MB")

        XCTAssertEqual(HttpClientLogic.statusTone(statusCode: 200, error: nil), "done")
        XCTAssertEqual(HttpClientLogic.statusTone(statusCode: 302, error: nil), "human")
        XCTAssertEqual(HttpClientLogic.statusTone(statusCode: 500, error: nil), "blocked")
        XCTAssertEqual(HttpClientLogic.statusTone(statusCode: 200, error: "timed out"), "blocked")

        XCTAssertEqual(HttpClientLogic.statusBadgeText(statusCode: 200, statusText: "", error: "boom"), "ERROR")
        XCTAssertEqual(HttpClientLogic.statusBadgeText(statusCode: 200, statusText: "200 OK", error: nil), "200 OK")
        XCTAssertEqual(HttpClientLogic.statusBadgeText(statusCode: 204, statusText: "", error: nil), "204")

        XCTAssertEqual(HttpClientLogic.defaultEnvColor(forName: "prod"), .red)
        XCTAssertEqual(HttpClientLogic.defaultEnvColor(forName: "nonprod"), .green)
        XCTAssertEqual(HttpClientLogic.defaultEnvColor(forName: "staging"), .amber)
    }

    // MARK: - Inheritance & Header Merging

    func testResolveInheritedAuthWalksFoldersAndHandlesCycles() {
        let ws = HttpWorkspace(
            id: "ws-1",
            name: "Core",
            defaultAuth: HttpAuthConfig(type: .bearer, token: "{{ws_tok}}"),
            defaultHeaders: [
                HttpKeyValue(key: "Accept", value: "application/json", enabled: true),
                HttpKeyValue(key: "X-Remove", value: "1", enabled: true),
            ]
        )
        let rootFolder = HttpFolder(
            id: "f-root",
            httpWorkspaceId: "ws-1",
            parentFolderId: nil,
            name: "Admin",
            defaultAuth: HttpAuthConfig(type: .apikey, apiKeyName: "X-Admin", apiKeyValue: "1", apiKeyIn: .header),
            defaultHeaders: [
                HttpKeyValue(key: "accept", value: "application/vnd.api+json", enabled: true),
                HttpKeyValue(key: "x-remove", value: "", enabled: false),
            ]
        )
        let leafFolder = HttpFolder(
            id: "f-leaf",
            httpWorkspaceId: "ws-1",
            parentFolderId: "f-root",
            name: "Users",
            defaultAuth: .inherit,
            defaultHeaders: [
                HttpKeyValue(key: "X-Trace", value: "yes", enabled: true),
            ]
        )
        let inheritAll = HttpFolder(
            id: "f-inherit",
            httpWorkspaceId: "ws-1",
            parentFolderId: nil,
            name: "Public",
            defaultAuth: .inherit
        )
        let cycleA = HttpFolder(id: "c-a", httpWorkspaceId: "ws-1", parentFolderId: "c-b", name: "Cycle A", defaultAuth: .inherit)
        let cycleB = HttpFolder(id: "c-b", httpWorkspaceId: "ws-1", parentFolderId: "c-a", name: "Cycle B", defaultAuth: .inherit)

        let bundle = HttpWorkspaceBundle(
            workspace: ws,
            environments: [],
            folders: [rootFolder, leafFolder, inheritAll, cycleA, cycleB],
            requests: []
        )

        let fromLeaf = HttpClientLogic.resolveInheritedAuth(bundle: bundle, folderId: "f-leaf")
        XCTAssertFalse(fromLeaf.fromWorkspace)
        XCTAssertEqual(fromLeaf.sourceName, "Admin")
        XCTAssertEqual(fromLeaf.auth.type, .apikey)
        XCTAssertEqual(fromLeaf.label, "Folder \"Admin\" (API Key)")

        let fromPublic = HttpClientLogic.resolveInheritedAuth(bundle: bundle, folderId: "f-inherit")
        XCTAssertTrue(fromPublic.fromWorkspace)
        XCTAssertEqual(fromPublic.auth.type, .bearer)
        XCTAssertEqual(fromPublic.label, "Workspace \"Core\" (Bearer Token)")

        let fromCycle = HttpClientLogic.resolveInheritedAuth(bundle: bundle, folderId: "c-a")
        XCTAssertTrue(fromCycle.fromWorkspace)

        // Accept + X-Trace enabled; X-Remove overridden to disabled case-insensitively.
        XCTAssertEqual(HttpClientLogic.inheritedEnabledHeaderCount(bundle: bundle, folderId: "f-leaf"), 2)
    }

    // MARK: - Body Preview & Shiki

    func testFormatBodyPreviewAndJSONSafety() async throws {
        let jsonPreview = HttpClientLogic.formatBodyPreview("{\"b\":2,\"a\":1}", contentType: "application/json; charset=utf-8")
        XCTAssertEqual(jsonPreview.detectedKind, "json")
        XCTAssertEqual(jsonPreview.shikiLanguage, "json")
        XCTAssertTrue(jsonPreview.isPrettyFormatted)
        XCTAssertTrue(jsonPreview.formatted.contains("\n"))

        let sniffedJson = HttpClientLogic.formatBodyPreview("[1,2]", contentType: nil)
        XCTAssertEqual(sniffedJson.detectedKind, "json")
        XCTAssertEqual(sniffedJson.shikiLanguage, "json")
        XCTAssertTrue(sniffedJson.isPrettyFormatted)

        // Top-level primitives must NOT crash formatJSON.
        XCTAssertNil(HttpClientLogic.formatJSON("42"))
        XCTAssertNil(HttpClientLogic.formatJSON("\"hello\""))
        XCTAssertNil(HttpClientLogic.formatJSON("{bad json"))

        let xmlPreview = HttpClientLogic.formatBodyPreview("<note><body>hi</body></note>", contentType: "application/xml")
        XCTAssertEqual(xmlPreview.detectedKind, "xml")
        XCTAssertEqual(xmlPreview.shikiLanguage, "html")

        let htmlPreview = HttpClientLogic.formatBodyPreview("<!DOCTYPE html><html></html>", contentType: nil)
        XCTAssertEqual(htmlPreview.detectedKind, "html")
        XCTAssertEqual(htmlPreview.shikiLanguage, "html")

        let yamlPreview = HttpClientLogic.formatBodyPreview("a: 1", contentType: "application/yaml")
        XCTAssertEqual(yamlPreview.shikiLanguage, "yaml")

        let plainPreview = HttpClientLogic.formatBodyPreview("hello world", contentType: "text/plain")
        XCTAssertEqual(plainPreview.detectedKind, "text")
        XCTAssertNil(plainPreview.shikiLanguage)

        // Smoke test Shiki highlighting on formatted JSON preview.
        let tokens = await CodeHighlighter.shared.highlight(jsonPreview.formatted, language: try XCTUnwrap(jsonPreview.shikiLanguage))
        XCTAssertNotNil(tokens)
        XCTAssertGreaterThan(tokens?.count ?? 0, 1)
    }

    // MARK: - Tree Building & Filtering

    func testTreeSortingCollapseFilteringAndOrphans() {
        let ws = HttpWorkspace(id: "ws-1", name: "API")
        let fAuth = HttpFolder(id: "f-auth", httpWorkspaceId: "ws-1", parentFolderId: nil, name: "Auth", sortOrder: 1)
        let fNested = HttpFolder(id: "f-nested", httpWorkspaceId: "ws-1", parentFolderId: "f-auth", name: "Tokens", sortOrder: 0)
        let fEmpty = HttpFolder(id: "f-empty", httpWorkspaceId: "ws-1", parentFolderId: nil, name: "Misc", sortOrder: 2)

        let r1 = HttpRequest(id: "r1", httpWorkspaceId: "ws-1", folderId: "f-nested", name: "Issue Token", method: "POST", url: "{{base_url}}/oauth/token")
        let r2 = HttpRequest(id: "r2", httpWorkspaceId: "ws-1", folderId: nil, name: "Health", method: "GET", url: "{{base_url}}/health")
        let rOrphan = HttpRequest(id: "r3", httpWorkspaceId: "ws-1", folderId: "missing-folder", name: "Orphan", method: "GET", url: "{{base_url}}/orphan")

        let bundle = HttpWorkspaceBundle(
            workspace: ws,
            environments: [],
            folders: [fEmpty, fAuth, fNested],
            requests: [rOrphan, r2, r1]
        )

        // Unfiltered, fAuth collapsed hides fNested & r1.
        let collapsedRows = HttpClientLogic.visibleTreeRows(bundle: bundle, filter: "", collapsedFolders: ["f-auth"])
        XCTAssertEqual(collapsedRows.map(\.id), ["folder:f-auth", "folder:f-empty", "req:r2", "req:r3"])

        // Unfiltered, expanded shows nested hierarchy sorted by sortOrder then name.
        let expandedRows = HttpClientLogic.visibleTreeRows(bundle: bundle, filter: "", collapsedFolders: [])
        XCTAssertEqual(expandedRows.map(\.id), ["folder:f-auth", "folder:f-nested", "req:r1", "folder:f-empty", "req:r2", "req:r3"])
        XCTAssertEqual(expandedRows[2].depth, 2)

        // Search auto-expands collapsed matching nested branch and hides non-matching branches.
        let filteredRows = HttpClientLogic.visibleTreeRows(bundle: bundle, filter: "oauth", collapsedFolders: ["f-auth"])
        XCTAssertEqual(filteredRows.map(\.id), ["folder:f-auth", "folder:f-nested", "req:r1"])
    }

    // MARK: - Variable Interpolation Preview

    func testInterpolatePreviewMergesWorkspaceDefaultsActiveEnvAndSecrets() {
        let ws = HttpWorkspace(
            id: "ws-1",
            name: "API",
            defaultVars: [
                HttpEnvVar(key: "base_url", value: "https://default.example.com", enabled: true),
                HttpEnvVar(key: "api_version", value: "v1", enabled: true),
                HttpEnvVar(key: "disabled_var", value: "ignored", enabled: false),
            ]
        )
        let env = HttpEnvironment(
            id: "env-1",
            httpWorkspaceId: "ws-1",
            name: "nonprod",
            variables: [
                HttpEnvVar(key: "base_url", value: "https://nonprod.example.com", enabled: true),
                HttpEnvVar(key: "api_key", value: "", secretHandle: "np-key", enabled: true),
            ]
        )

        let res = HttpClientLogic.interpolatePreview(
            "{{base_url}}/{{api_version}}/items?key={{api_key}}&tok={{secret:svc-tok}}&x={{disabled_var}}&y={{missing}}",
            workspace: ws,
            activeEnvironment: env
        )

        XCTAssertEqual(
            res.resolved,
            "https://nonprod.example.com/v1/items?key=•••(secret:np-key)&tok=•••(secret:svc-tok)&x={{disabled_var}}&y={{missing}}"
        )
        XCTAssertEqual(res.secretReferences, ["np-key", "svc-tok"])
        XCTAssertEqual(res.unresolvedVariables, ["disabled_var", "missing"])
        XCTAssertEqual(res.substitutedVariables, ["base_url": "https://nonprod.example.com", "api_version": "v1"])
    }

    // MARK: - Chrome Projection

    func testChromeToolbarItemsAndParsers() {
        let ws1 = HttpWorkspace(id: "w1", name: "One", activeEnvironmentId: "e1")
        let ws2 = HttpWorkspace(id: "w2", name: "Two")
        let env = HttpEnvironment(id: "e1", httpWorkspaceId: "w1", name: "nonprod")
        let bundle = HttpWorkspaceBundle(workspace: ws1, environments: [env])

        let items = HttpClientChrome.toolbarItems(
            workspaces: [ws1, ws2],
            effectiveWorkspaceId: "w1",
            bundle: bundle,
            isAuthEnvMode: true
        )

        XCTAssertEqual(items.first(where: { $0.id == HttpClientChrome.workspaceMenuId })?.label, "One")
        XCTAssertEqual(items.first(where: { $0.id == HttpClientChrome.environmentMenuId })?.label, "nonprod")
        XCTAssertEqual(items.first(where: { $0.id == HttpClientChrome.authEnvToggleId })?.on, true)
        XCTAssertEqual(HttpClientChrome.parseWorkspaceItemId("ws:w1"), "w1")
        XCTAssertNil(HttpClientChrome.parseWorkspaceItemId("env:e1"))
        XCTAssertEqual(HttpClientChrome.parseEnvironmentItemId("env:"), .some(nil))
        XCTAssertEqual(HttpClientChrome.parseEnvironmentItemId("env:e1"), .some("e1"))
        XCTAssertNil(HttpClientChrome.parseEnvironmentItemId("ws:w1"))
    }
}
