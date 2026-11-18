import { Suspense, use } from "react";
import { PageScreen } from "../../_components/page-screen";

function Loader({ params }: { params: PageProps<"/knowledge/[id]/[[...slug]]">["params"] }) {
  const { id } = use(params);
  return <PageScreen id={id} />;
}

export default function Page({ params }: PageProps<"/knowledge/[id]/[[...slug]]">) {
  // params are URL data, which streams inside a Suspense boundary.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
