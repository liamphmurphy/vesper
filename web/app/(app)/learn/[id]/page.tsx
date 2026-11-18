import { Suspense, use } from "react";
import { CourseScreen } from "../_components/course-screen";

function Loader({ params }: { params: PageProps<"/learn/[id]">["params"] }) {
  const { id } = use(params);
  return <CourseScreen id={decodeURIComponent(id)} />;
}

export default function Page({ params }: PageProps<"/learn/[id]">) {
  // params are request-time data under Cache Components, so they stream in Suspense.
  return (
    <Suspense>
      <Loader params={params} />
    </Suspense>
  );
}
