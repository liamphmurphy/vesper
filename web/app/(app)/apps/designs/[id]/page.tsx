import { Suspense, use } from "react";
import { DesignEditor } from "../_components/design-editor";

// Hosted inside Knowledge's native macOS shell (KnowledgePageEditorSlot) as well as direct links.
function Loader({ params }: { params: PageProps<"/apps/designs/[id]">["params"] }) {
  const { id } = use(params);
  return <DesignEditor key={id} id={id} />;
}

export default function Page({ params }: PageProps<"/apps/designs/[id]">) {
  // params and the query it keeps are URL data, which stream in Suspense.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
