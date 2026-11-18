// Library's left column: the source switch (Yours / From spaces) and either the keepsake tabs or
// the project documents' filters (library/library-screen.tsx, library/_components/project-docs.tsx).
import type { NavAction, NavModel, NavPicker } from "../protocol.ts";

export const LIBRARY_NAV_ID = "library";
export const LIBRARY_SOURCE_PICKER = "source";
export const LIBRARY_SEARCH = "library-search";

export type LibrarySourceValue = "yours" | "projects";

export const librarySourceHref = (source: LibrarySourceValue) => (source === "yours" ? "/library" : "/library?source=projects");

function sourcePicker(source: LibrarySourceValue): NavPicker {
  return {
    id: LIBRARY_SOURCE_PICKER,
    value: source,
    options: [
      { value: "yours", label: "Yours" },
      { value: "projects", label: "From spaces" },
    ],
  };
}

export function buildKeepsakesNavModel(input: { tabs: readonly { key: string; label: string }[]; tab: string }): NavModel {
  return {
    id: LIBRARY_NAV_ID,
    title: "Library",
    picker: sourcePicker("yours"),
    sections: [{ id: "tabs", items: input.tabs.map((t) => ({ id: t.key, title: t.label })) }],
    selectedId: input.tab,
  };
}

export function buildProjectDocsNavModel(input: {
  tabs: readonly { key: string; label: string; href: string }[];
  type: string;
  counts?: Record<string, number | undefined>;
  search: string;
  projectAction: NavAction;
}): NavModel {
  return {
    id: LIBRARY_NAV_ID,
    title: "Library",
    picker: sourcePicker("projects"),
    actions: [input.projectAction],
    search: { id: LIBRARY_SEARCH, placeholder: "Search titles and contents", value: input.search },
    sections: [
      {
        id: "types",
        items: input.tabs.map((t) => {
          const n = input.counts?.[t.key];
          return { id: t.key, title: t.label, href: t.href, ...(n !== undefined ? { trailing: String(n) } : {}) };
        }),
      },
    ],
    selectedId: input.type,
  };
}
