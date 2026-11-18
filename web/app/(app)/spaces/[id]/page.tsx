import { Suspense, use } from "react";
import { SpaceScreen } from "../_components/space-screen";

function Loader({ params }: { params: PageProps<"/spaces/[id]">["params"] }) {
  const { id } = use(params);
  return <SpaceScreen id={decodeURIComponent(id)} />;
}

export default function Page({ params }: PageProps<"/spaces/[id]">) {
  // params are request-time data under Cache Components, so they stream in Suspense.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
