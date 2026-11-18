import { Suspense, use } from "react";
import { PresentDeck } from "./present-deck";

function Loader({ params }: { params: PageProps<"/present/slides/[id]">["params"] }) {
  const { id } = use(params);
  return <PresentDeck id={id} />;
}

/** A deck presented full screen, outside the app shell (mockup 4/6). */
export default function PresentPage({ params }: PageProps<"/present/slides/[id]">) {
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
