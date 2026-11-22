import { Suspense } from "react";
import { EpicsScreen } from "./epics-screen";

export default function EpicsListPage() {
  return (
    <Suspense>
      <EpicsScreen />
    </Suspense>
  );
}
