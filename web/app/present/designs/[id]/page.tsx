import { Suspense, use } from "react";
import { PresentDesign } from "./present-design";

function Loader({ params }: { params: PageProps<"/present/designs/[id]">["params"] }) {
  const { id } = use(params);
  return <PresentDesign id={id} />;
}

/** A design's prototype played full screen, outside the app shell (ADR-designs §4, the Slides Present shell). */
export default function PresentPage({ params }: PageProps<"/present/designs/[id]">) {
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
