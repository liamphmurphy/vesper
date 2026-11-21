/** Work has one URL and one mounted conversation, even when its brief takes focus. */
export type WorkView = "activity" | "tickets" | "epics";
export function workView(params: URLSearchParams): WorkView {
  const view = params.get("view");
  return view === "tickets" || view === "epics" ? view : "activity";
}

export function workHref(
  params: URLSearchParams,
  patch: Record<string, string | null>,
): string {
  const next = new URLSearchParams(params);
  for (const [key, value] of Object.entries(patch)) {
    if (value === null) next.delete(key);
    else next.set(key, value);
  }
  return `/work${next.size ? `?${next}` : ""}`;
}

/** Translate `/runs/:id` into `/work?run=:id`; tickets and epics open their canonical routes. */
export function workTarget(
  pathname: string,
  params: URLSearchParams,
): string | null {
  const run = /^\/runs\/([^/]+)$/.exec(pathname);
  if (run)
    return workHref(params, {
      run: decodeURIComponent(run[1]),
      view: null,
      context: null,
    });
  return null;
}

/** Read at the event boundary: a preceding native-history update may not have rendered yet. */
export function updateWorkUrl(
  patch: Record<string, string | null>,
  replace = false,
) {
  const href = workHref(new URLSearchParams(window.location.search), patch);
  if (replace) window.history.replaceState(null, "", href);
  else window.history.pushState(null, "", href);
}
