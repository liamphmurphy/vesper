import { Preview } from "./preview";

// A bare <DesignSvg> for the render-parity e2e spec (it compares the editor's
// drawing with the worker's PNG). The web server only serves this path with the
// worker's bearer token (?token=) and 404s it otherwise (design-worker/handler.ts).
export default function Page() {
  return <Preview />;
}
