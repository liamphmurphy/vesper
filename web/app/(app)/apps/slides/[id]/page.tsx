import { Suspense, use } from "react";
import { DeckScreen } from "../_components/deck-screen";

// Hosted inside Knowledge's native macOS shell (KnowledgePageEditorSlot) as well as direct links.
function Loader({ params }: { params: PageProps<"/apps/slides/[id]">["params"] }) {
  const { id } = use(params);
  return <DeckScreen key={id} id={id} />;
}

export default function Page({ params }: PageProps<"/apps/slides/[id]">) {
  // params and the query it keeps are URL data, which stream in Suspense.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
