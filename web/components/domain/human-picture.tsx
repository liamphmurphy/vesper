"use client";

import { useState, type ReactNode } from "react";

/**
 * A person's uploaded picture cropped to the avatar circle. If it fails to load
 * (or the src changes to one that did), `fallback` (the initials) shows instead.
 */
export function HumanPicture({ src, fallback }: { src: string; fallback: ReactNode }) {
  const [failed, setFailed] = useState<string>();
  if (failed === src) return <>{fallback}</>;
  return (
    // same-origin API image
    <img src={src} alt="" aria-hidden onError={() => setFailed(src)} className="size-full rounded-full object-cover" />
  );
}
