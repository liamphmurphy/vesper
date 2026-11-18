import { Suspense, use } from "react";
import { LegacyRedirect } from "../../../knowledge/_components/legacy-redirect";
import { DocScreen } from "../_components/doc-screen";

function Loader({ params }: { params: PageProps<"/apps/docs/[id]">["params"] }) {
  const { id } = use(params);
  // A Doc moved into Knowledge opens there; a canvas that never was a Doc still opens here.
  return <LegacyRedirect from={`/apps/docs/${id}`} fallback={<DocScreen id={id} />} />;
}

export default function Page({ params }: PageProps<"/apps/docs/[id]">) {
  // The drawer's conversation reads search params, which stream in Suspense.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
