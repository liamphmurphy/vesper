// A custom app's own views (its manifest's nav) as a NavModel for the native sidebar.
import type { NativeAction } from "../actions.ts";
import type { NavModel } from "../protocol.ts";

export const CUSTOM_APP_NAV_ID = "custom-app";
export const viewId = (id: string) => `view:${id}`;
export const parseViewId = (id: string): string | null => (id.startsWith("view:") ? id.slice("view:".length) : null);

export function buildCustomAppNav(i: { title?: string; items: readonly { id: string; label: string; icon?: string }[]; currentId?: string }): NavModel {
  return {
    id: CUSTOM_APP_NAV_ID,
    title: i.title,
    sections: [{ id: "views", title: "Views", items: i.items.map((v) => ({ id: viewId(v.id), title: v.label, ...(v.icon ? { icon: v.icon } : {}) })) }],
    selectedId: i.currentId ? viewId(i.currentId) : null,
  };
}

/** The header's Reload, Standalone Window, and Permissions buttons. */
export function buildCustomAppActions(i: {
  reload: () => void;
  permissions: () => void;
  openStandalone?: () => void;
}): NativeAction[] {
  const actions: NativeAction[] = [
    { id: "app.reload", label: "Reload app", icon: "refresh", kind: "button", run: i.reload },
  ];
  if (i.openStandalone) {
    actions.push({
      id: "app.standalone",
      label: "Open in Standalone Window",
      icon: "window",
      kind: "button",
      run: i.openStandalone,
    });
  }
  actions.push({ id: "app.permissions", label: "Permissions", icon: "shield", kind: "button", showsLabel: true, run: i.permissions });
  return actions;
}
