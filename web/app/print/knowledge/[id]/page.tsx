import { Suspense, use } from "react";
import { PrintKnowledge } from "./print-knowledge";

function Loader({ params }: { params: PageProps<"/print/knowledge/[id]">["params"] }) {
  const { id } = use(params);
  return <PrintKnowledge id={id} />;
}

/** A Knowledge page laid out for paper, outside the app shell. Print or save as PDF opens it. */
export default function PrintKnowledgePage({ params }: PageProps<"/print/knowledge/[id]">) {
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
