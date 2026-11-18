import { Suspense, use } from "react";
import { LegacyRedirect } from "../../knowledge/_components/legacy-redirect";
import { WikiScreen } from "../_components/wiki-screen";

// Segments arrive percent-encoded ("Rollback%20runbook").
function decode(s: string) {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

function Loader({ params }: { params: PageProps<"/wiki/[...path]">["params"] }) {
  const { path } = use(params);
  const full = path.map(decode).join("/");
  // Wiki pages live in Knowledge now; the old screen only shows for a path nothing holds.
  return <LegacyRedirect from={`/wiki/${path.join("/")}`} fallback={<WikiScreen path={full} />} />;
}

export default function WikiPathPage({ params }: PageProps<"/wiki/[...path]">) {
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
