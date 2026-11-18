import { StrictMode } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { RouterProvider } from "react-router";
import { createAppRouter } from "@/lib/next-compat/routes";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    {/* flushSync: a navigation commits in the task that changes the URL, as Next does. */}
    <RouterProvider router={createAppRouter()} flushSync={flushSync} />
  </StrictMode>,
);
