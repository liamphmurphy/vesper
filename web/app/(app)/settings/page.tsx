import { Suspense } from "react";
import { SettingsScreen } from "./settings-screen";

export default function Settings() {
  return (
    <Suspense>
      <SettingsScreen />
    </Suspense>
  );
}
