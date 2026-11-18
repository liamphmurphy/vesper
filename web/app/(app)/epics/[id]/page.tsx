import { Suspense, use } from "react";
import { EpicDetailScreen } from "./epic-detail-screen";

function Loader({ params }: { params: PageProps<"/epics/[id]">["params"] }) {
  const { id } = use(params);
  return <EpicDetailScreen epicId={decodeURIComponent(id)} />;
}

export default function EpicPage({ params }: PageProps<"/epics/[id]">) {
  // params are request-time data under Cache Components, so they stream in Suspense.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
