export type ReviewFilterPrefs = {
  direct: boolean;
  team: boolean;
};

export type ReviewRequestLike = {
  id: string;
  direct: boolean;
  team: boolean;
};

/** Maps dismissed PR IDs (`owner/repo#number`) to the `updated_at` marker when dismissed. */
export type DismissedReviewRequests = Record<string, string>;

export type DismissibleReviewRequest = {
  id: string;
  updated_at: string;
};

export const REVIEW_FILTERS_STORAGE_KEY = "vesper:pr-review-filters";
export const DISMISSED_STORAGE_KEY = "vesper:pr-review-dismissed";

const DEFAULT_PREFS: ReviewFilterPrefs = { direct: true, team: true };

export function parseReviewFilterPrefs(raw: string | null): ReviewFilterPrefs {
  if (!raw) return { ...DEFAULT_PREFS };
  try {
    const parsed = JSON.parse(raw) as Partial<ReviewFilterPrefs>;
    return {
      direct: typeof parsed.direct === "boolean" ? parsed.direct : true,
      team: typeof parsed.team === "boolean" ? parsed.team : true,
    };
  } catch {
    return { ...DEFAULT_PREFS };
  }
}

export function loadReviewFilterPrefs(storage?: Pick<Storage, "getItem">): ReviewFilterPrefs {
  if (!storage) return { ...DEFAULT_PREFS };
  try {
    return parseReviewFilterPrefs(storage.getItem(REVIEW_FILTERS_STORAGE_KEY));
  } catch {
    return { ...DEFAULT_PREFS };
  }
}

export function saveReviewFilterPrefs(storage: Pick<Storage, "setItem"> | undefined, prefs: ReviewFilterPrefs): void {
  if (!storage) return;
  try {
    storage.setItem(REVIEW_FILTERS_STORAGE_KEY, JSON.stringify(prefs));
  } catch {
    // Ignore storage quota or privacy-mode errors.
  }
}

function dismissMarker(updatedAt: string): string {
  return updatedAt || "dismissed";
}

export function parseDismissedReviewRequests(raw: string | null): DismissedReviewRequests {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    const out: DismissedReviewRequests = {};
    for (const [id, updatedAt] of Object.entries(parsed)) {
      if (id && typeof updatedAt === "string" && updatedAt.length > 0) {
        out[id] = updatedAt;
      }
    }
    return out;
  } catch {
    return {};
  }
}

export function loadDismissedReviewRequests(storage?: Pick<Storage, "getItem">): DismissedReviewRequests {
  if (!storage) return {};
  try {
    return parseDismissedReviewRequests(storage.getItem(DISMISSED_STORAGE_KEY));
  } catch {
    return {};
  }
}

export function saveDismissedReviewRequests(
  storage: Pick<Storage, "setItem"> | undefined,
  dismissed: DismissedReviewRequests,
): void {
  if (!storage) return;
  try {
    storage.setItem(DISMISSED_STORAGE_KEY, JSON.stringify(dismissed));
  } catch {
    // Ignore storage quota or privacy-mode errors.
  }
}

export function isReviewRequestDismissed(
  item: DismissibleReviewRequest,
  dismissed: DismissedReviewRequests,
): boolean {
  if (!Object.prototype.hasOwnProperty.call(dismissed, item.id)) return false;
  return dismissed[item.id] === dismissMarker(item.updated_at);
}

export function excludeDismissedReviewRequests<T extends DismissibleReviewRequest>(
  items: readonly T[],
  dismissed: DismissedReviewRequests,
): T[] {
  return items.filter((item) => !isReviewRequestDismissed(item, dismissed));
}

export function dismissReviewRequests(
  dismissed: DismissedReviewRequests,
  items: readonly DismissibleReviewRequest[],
): DismissedReviewRequests {
  if (items.length === 0) return dismissed;
  const next: DismissedReviewRequests = { ...dismissed };
  for (const item of items) {
    next[item.id] = dismissMarker(item.updated_at);
  }
  return next;
}

export function restoreReviewRequests(
  dismissed: DismissedReviewRequests,
  items: readonly Pick<DismissibleReviewRequest, "id">[],
): DismissedReviewRequests {
  const next: DismissedReviewRequests = { ...dismissed };
  let changed = false;
  for (const item of items) {
    if (Object.prototype.hasOwnProperty.call(next, item.id)) {
      delete next[item.id];
      changed = true;
    }
  }
  return changed ? next : dismissed;
}

export function filterReviewRequests<T extends ReviewRequestLike>(items: readonly T[], prefs: ReviewFilterPrefs): T[] {
  return items.filter((item) => (prefs.direct && item.direct) || (prefs.team && item.team));
}

export function countReviewRequests(items: readonly ReviewRequestLike[]): { direct: number; team: number } {
  let direct = 0;
  let team = 0;
  for (const item of items) {
    if (item.direct) direct += 1;
    if (item.team) team += 1;
  }
  return { direct, team };
}

export function authorInitials(login: string): string {
  const clean = login.replace(/[^a-zA-Z0-9_-]/g, "");
  if (!clean) return "GH";
  const parts = clean.split(/[-_]+/).filter(Boolean);
  if (parts.length >= 2) {
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
  return clean.slice(0, 2).toUpperCase();
}

export function relativeAge(iso: string, nowMs = Date.now()): string {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return "";
  const sec = Math.max(0, Math.floor((nowMs - t) / 1000));
  if (sec < 60) return "just now";
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const days = Math.floor(hr / 24);
  return `${days}d ago`;
}
