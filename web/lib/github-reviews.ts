export type ReviewFilterPrefs = {
  direct: boolean;
  team: boolean;
};

export type ReviewRequestLike = {
  id: string;
  direct: boolean;
  team: boolean;
};

const STORAGE_KEY = "vesper:pr-review-filters";
const DEFAULT_PREFS: ReviewFilterPrefs = { direct: true, team: true };

export function loadReviewFilterPrefs(storage?: Pick<Storage, "getItem">): ReviewFilterPrefs {
  if (!storage) return { ...DEFAULT_PREFS };
  try {
    const raw = storage.getItem(STORAGE_KEY);
    if (!raw) return { ...DEFAULT_PREFS };
    const parsed = JSON.parse(raw) as Partial<ReviewFilterPrefs>;
    return {
      direct: typeof parsed.direct === "boolean" ? parsed.direct : true,
      team: typeof parsed.team === "boolean" ? parsed.team : true,
    };
  } catch {
    return { ...DEFAULT_PREFS };
  }
}

export function saveReviewFilterPrefs(storage: Pick<Storage, "setItem"> | undefined, prefs: ReviewFilterPrefs): void {
  if (!storage) return;
  try {
    storage.setItem(STORAGE_KEY, JSON.stringify(prefs));
  } catch {
    // Ignore storage quota or privacy-mode errors.
  }
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
