import { Suspense, use } from "react";
import { CustomAppScreen } from "./_components/custom-app-screen";

function Loader({ params }: { params: PageProps<"/apps/[slug]">["params"] }) {
  const { slug } = use(params);
  return <CustomAppScreen slug={decodeURIComponent(slug)} />;
}

export default function CustomAppPage({ params }: PageProps<"/apps/[slug]">) {
  // params are request-time data under Cache Components, so they stream in Suspense.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
