import { Suspense, use } from "react";
import { DocScreen } from "../_components/doc-screen";

// Hosted inside Knowledge's native macOS shell (KnowledgePageEditorSlot) as well as direct links.
function Loader({ params }: { params: PageProps<"/apps/docs/[id]">["params"] }) {
  const { id } = use(params);
  return <DocScreen key={id} id={id} />;
}

export default function Page({ params }: PageProps<"/apps/docs/[id]">) {
  // The drawer's conversation reads search params, which stream in Suspense.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
