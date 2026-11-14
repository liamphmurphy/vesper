"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect } from "react";
import { useQuery } from "@tanstack/react-query";
import { fetchCanvasPage } from "@/lib/api/knowledge-hooks";
import { pageHref } from "@/lib/knowledge";
import { Banner, Skeleton } from "@/components/ui/primitives";

/**
 * An old /apps/slides/<id> or /apps/designs/<id> link (or a deck or design just made): every deck
 * and design is a Knowledge page now (LAZYAGENTS-212), so this finds that page and replaces the
 * address with it, keeping the query (?review=1, ?brief=…) the editor reads.
 */
export function CanvasPageRedirect({ canvasId, what }: { canvasId: string; what: "deck" | "design" }) {
  const router = useRouter();
  const search = useSearchParams();
  const page = useQuery({ queryKey: ["canvas-page", canvasId], queryFn: () => fetchCanvasPage(canvasId), retry: false });
  const query = search.toString();
  useEffect(() => {
    if (page.data) router.replace(`${pageHref(page.data.id, page.data.title)}${query ? `?${query}` : ""}`);
  }, [page.data, query, router]);
  if (page.isError)
    return (
      <div className="p-8">
        <Banner tone="blocked" title={`This ${what} isn't available`}>
          It may have been deleted, or it&apos;s private to someone else.{" "}
          <Link href="/knowledge" className="underline">
            Open Knowledge
          </Link>
        </Banner>
      </div>
    );
  return (
    <div aria-busy="true" className="mx-auto w-full max-w-[680px] space-y-4 px-6 pt-16">
      <Skeleton className="h-9 w-1/2" />
      <Skeleton className="h-4 w-full" />
    </div>
  );
}
