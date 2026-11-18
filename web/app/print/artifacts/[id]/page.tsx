import { Suspense, use } from "react";
import { PrintArtifact } from "./print-artifact";

function Loader({ params }: { params: PageProps<"/print/artifacts/[id]">["params"] }) {
  const { id } = use(params);
  return <PrintArtifact id={id} />;
}

/** A markdown artifact laid out for paper, outside the app shell. Export PDF opens it. */
export default function PrintArtifactPage({ params }: PageProps<"/print/artifacts/[id]">) {
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
