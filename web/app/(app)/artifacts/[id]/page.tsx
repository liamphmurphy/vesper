import { Suspense, use } from "react";
import { ArtifactScreen } from "./artifact-screen";

function Loader({ params }: { params: PageProps<"/artifacts/[id]">["params"] }) {
  const { id } = use(params);
  return <ArtifactScreen id={id} />;
}

export default function ArtifactPage({ params }: PageProps<"/artifacts/[id]">) {
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
