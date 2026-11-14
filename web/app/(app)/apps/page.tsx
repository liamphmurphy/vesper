import { Suspense } from "react";
import { AppsHome } from "./_components/apps-home";

export default function CustomAppsPage() {
  return (
    <Suspense>
      <AppsHome />
    </Suspense>
  );
}
