import { Suspense, use } from "react";
import { RunLogScreen } from "./run-log";

function Loader({ params }: { params: PageProps<"/runs/[id]">["params"] }) {
  const { id } = use(params);
  return <RunLogScreen id={id} />;
}

export default function RunPage({ params }: PageProps<"/runs/[id]">) {
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
