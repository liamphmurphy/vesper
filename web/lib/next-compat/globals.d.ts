// Next generated these global helper types (`next typegen`); the static app declares them itself.
import type { ReactNode } from "react";

type ParamsOf<R extends string> = R extends `${infer Head}/${infer Rest}`
  ? ParamsOf<Head> & ParamsOf<Rest>
  : R extends `[[...${infer N}]]`
    ? { [K in N]?: string[] }
    : R extends `[...${infer N}]`
      ? { [K in N]: string[] }
      : R extends `[${infer N}]`
        ? { [K in N]: string }
        : unknown;

declare global {
  type PageProps<R extends string> = {
    params: Promise<ParamsOf<R>>;
    searchParams: Promise<Record<string, string | string[] | undefined>>;
  };
  type LayoutProps<R extends string> = { children: ReactNode; params: Promise<ParamsOf<R>> };
}
