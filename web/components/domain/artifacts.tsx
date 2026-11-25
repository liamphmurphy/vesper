/** "ADR-012 · Postgres declarative partitioning" for numbered types. */
export function artifactTitle(a: { title: string; display_id?: string }) {
  return a.display_id ? `${a.display_id} · ${a.title}` : a.title;
}
