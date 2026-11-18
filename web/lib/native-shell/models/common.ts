// Small helpers shared by the screen models.
import { initials } from "../chats-model.ts";
import type { Avatar } from "../protocol.ts";

/** An avatar for the shell: initials, a literal color only, and an absolute image url. */
export function navAvatar(name: string, color?: string, imageUrl?: string | null, origin?: string): Avatar {
  const a: Avatar = { initials: initials(name) };
  if (color && /^#|^rgb|^hsl/i.test(color)) a.color = color;
  if (imageUrl) {
    try {
      a.imageUrl = origin ? new URL(imageUrl, origin).toString() : imageUrl;
    } catch {
      /* no image */
    }
  }
  return a;
}

/** The page's origin for absolute avatar urls; undefined while rendering on the server. */
export function pageOrigin(): string | undefined {
  return typeof window === "undefined" ? undefined : window.location.origin;
}
