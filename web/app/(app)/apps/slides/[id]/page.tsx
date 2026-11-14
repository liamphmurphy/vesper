import { Suspense } from "react";
import { CanvasPageRedirect } from "@/components/domain/canvas-page-redirect";

// Every deck is a Knowledge page (LAZYAGENTS-212): the old address opens it there.
async function Loader({ params }: { params: PageProps<"/apps/slides/[id]">["params"] }) {
  const { id } = await params;
  return <CanvasPageRedirect canvasId={id} what="deck" />;
}

export default function Page({ params }: PageProps<"/apps/slides/[id]">) {
  // params and the query it keeps are URL data, which stream in Suspense.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
