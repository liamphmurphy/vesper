import Foundation

/// Toolbar and chrome projection for `/http` (decoupled from SwiftUI views so macOS chrome stays separate from domain logic).
public enum HttpClientChrome {
    public static let workspaceMenuId = "http.workspace"
    public static let newWorkspaceId = "http.newWorkspace"
    public static let deleteWorkspaceId = "http.deleteWorkspace"
    public static let environmentMenuId = "http.env"
    public static let importId = "http.import"
    public static let authEnvToggleId = "http.authEnv"
    public static let refreshId = "http.refresh"

    public static func workspaceItemId(_ id: String) -> String { "ws:\(id)" }

    public static func parseWorkspaceItemId(_ raw: String) -> String? {
        guard raw.hasPrefix("ws:") else { return nil }
        let id = String(raw.dropFirst(3))
        return id.isEmpty ? nil : id
    }

    public static func environmentItemId(_ id: String?) -> String { "env:\(id ?? "")" }

    /// Returns `.some(nil)` for `"env:"` (clear environment), `.some(id)` for `"env:<id>"`, or `nil` for unrelated items.
    public static func parseEnvironmentItemId(_ raw: String) -> String?? {
        guard raw.hasPrefix("env:") else { return nil }
        let id = String(raw.dropFirst(4))
        return .some(id.isEmpty ? nil : id)
    }

    public static func toolbarItems(
        workspaces: [HttpWorkspace],
        effectiveWorkspaceId: String?,
        bundle: HttpWorkspaceBundle?,
        isAuthEnvMode: Bool
    ) -> [ToolbarItem] {
        var items: [ToolbarItem] = []

        if !workspaces.isEmpty {
            let label = workspaces.first(where: { $0.id == effectiveWorkspaceId })?.name ?? "Workspace"
            items.append(ToolbarItem(
                id: workspaceMenuId,
                label: label,
                icon: "server",
                kind: .menu,
                menu: workspaces.map { ws in
                    MenuItem(
                        id: workspaceItemId(ws.id),
                        label: ws.name,
                        checked: ws.id == effectiveWorkspaceId
                    )
                },
                showsLabel: true,
                placement: .leading
            ))
        }

        items.append(ToolbarItem(
            id: newWorkspaceId,
            label: "New workspace",
            icon: "plus",
            kind: .button,
            showsLabel: true,
            placement: .leading
        ))

        if let bundle {
            let activeEnv = bundle.environments.first { $0.id == bundle.workspace.activeEnvironmentId }
            var envMenu: [MenuItem] = [
                MenuItem(
                    id: environmentItemId(nil),
                    label: "No environment",
                    checked: bundle.workspace.activeEnvironmentId == nil
                ),
            ]
            envMenu += bundle.environments.map { env in
                MenuItem(
                    id: environmentItemId(env.id),
                    label: env.name,
                    checked: env.id == bundle.workspace.activeEnvironmentId
                )
            }

            items.append(ToolbarItem(
                id: deleteWorkspaceId,
                label: "Delete workspace",
                icon: "trash",
                kind: .button
            ))
            items.append(ToolbarItem(
                id: environmentMenuId,
                label: activeEnv?.name ?? "No environment",
                icon: "sliders",
                kind: .menu,
                menu: envMenu,
                showsLabel: true
            ))
            items.append(ToolbarItem(
                id: importId,
                label: "Import",
                icon: "upload",
                kind: .button,
                showsLabel: true
            ))
            items.append(ToolbarItem(
                id: authEnvToggleId,
                label: "Auth & Env",
                icon: "sliders",
                kind: .toggle,
                on: isAuthEnvMode,
                showsLabel: true
            ))
        }

        items.append(ToolbarItem(
            id: refreshId,
            label: "Refresh",
            icon: "refresh",
            kind: .button
        ))

        return items
    }
}
