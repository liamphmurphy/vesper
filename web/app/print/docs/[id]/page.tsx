import { Suspense, use } from "react";
import { PrintDoc } from "./print-doc";

function Loader({ params }: { params: PageProps<"/print/docs/[id]">["params"] }) {
  const { id } = use(params);
  return <PrintDoc id={id} />;
}

/** A Docs app document laid out for paper, outside the app shell. Its PDF button opens it. */
export default function PrintDocPage({ params }: PageProps<"/print/docs/[id]">) {
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
