// Pure parsers for ```gallery and ```product fences in chat replies
// (components/domain/media-fence). Kept free of React so `npm run test:unit` covers it.

export const isGalleryFence = (info: string | undefined) =>
  (info ?? "").trim().split(/\s+/)[0]?.toLowerCase() === "gallery";

export const isProductFence = (info: string | undefined) =>
  (info ?? "").trim().split(/\s+/)[0]?.toLowerCase() === "product";

export type GalleryItem = {
  image?: string;
  url?: string;
  caption?: string;
  source?: string;
};

export type GallerySpec = {
  title?: string;
  items: GalleryItem[];
};

export type ProductItem = {
  name: string;
  url?: string;
  image?: string;
  price?: string;
  rating?: string;
  badge?: string;
  description?: string;
  specs: string[];
};

export type ProductSpec = {
  title?: string;
  items: ProductItem[];
};

function safeHttpUrl(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const trimmed = raw.trim();
  if (!trimmed) return undefined;
  try {
    const u = new URL(trimmed);
    if (u.protocol !== "https:" && u.protocol !== "http:") return undefined;
    if (u.username || u.password) return undefined;
    return trimmed;
  } catch {
    return undefined;
  }
}

function cleanText(raw: unknown, maxLen = 240): string | undefined {
  if (typeof raw !== "string") return undefined;
  const s = raw.replace(/\s+/g, " ").trim();
  if (!s) return undefined;
  return s.length > maxLen ? `${s.slice(0, maxLen - 1).trimEnd()}…` : s;
}

/** Parses a ```gallery JSON fence, dropping unsafe URLs and empty entries. */
export function parseGallery(code: string): GallerySpec | null {
  let raw: unknown;
  try {
    raw = JSON.parse(code);
  } catch {
    return null;
  }
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (!Array.isArray(obj.items)) return null;
  const items: GalleryItem[] = [];
  for (const entry of obj.items) {
    if (!entry || typeof entry !== "object") continue;
    const e = entry as Record<string, unknown>;
    const image = safeHttpUrl(e.image);
    const url = safeHttpUrl(e.url);
    if (!image && !url) continue;
    items.push({
      image,
      url,
      caption: cleanText(e.caption ?? e.title, 200),
      source: cleanText(e.source, 80),
    });
    if (items.length >= 12) break;
  }
  if (items.length === 0) return null;
  return { title: cleanText(obj.title, 120), items };
}

/** Parses a ```product JSON fence, returning validated product cards. */
export function parseProduct(code: string): ProductSpec | null {
  let raw: unknown;
  try {
    raw = JSON.parse(code);
  } catch {
    return null;
  }
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (!Array.isArray(obj.items)) return null;
  const items: ProductItem[] = [];
  for (const entry of obj.items) {
    if (!entry || typeof entry !== "object") continue;
    const e = entry as Record<string, unknown>;
    const name = cleanText(e.name ?? e.title, 140);
    if (!name) continue;
    const url = safeHttpUrl(e.url);
    const image = safeHttpUrl(e.image);
    const specs = Array.isArray(e.specs)
      ? e.specs.map((s) => cleanText(s, 60)).filter((s): s is string => !!s).slice(0, 8)
      : [];
    items.push({
      name,
      url,
      image,
      price: cleanText(e.price, 40),
      rating: cleanText(e.rating, 32),
      badge: cleanText(e.badge, 40),
      description: cleanText(e.description, 220),
      specs,
    });
    if (items.length >= 8) break;
  }
  if (items.length === 0) return null;
  return { title: cleanText(obj.title, 120), items };
}

/** Hostname for display badges (strips leading www.). */
export function mediaHost(raw: string | undefined): string {
  if (!raw) return "";
  try {
    return new URL(raw).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}
