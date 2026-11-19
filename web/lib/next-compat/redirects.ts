// The redirects next.config.ts used to declare, kept as data so the browser (and a unit test) can apply them.
// As in Next, the incoming query carries over; a query on the destination wins on a clash.
import { customizationRedirect } from "../settings-nav.ts";

type Rule = { source: string; destination: string; hasQuery?: { key: string; value: RegExp } };

export const REDIRECTS: Rule[] = [
  // Memory, Personas and Customization unified into Settings; ?id= and filter params carry over.
  { source: "/memory", destination: "/settings?section=memory" },
  { source: "/personas", destination: "/settings?section=personas" },
  // Agents sit beside Personas in Settings; /agents/:handle stays the editor.
  { source: "/agents", destination: "/settings?section=personas&filter=tickets" },
  // Board and Epics are layouts of Tickets; their filters (?project=, ?epic=) carry over.
  { source: "/board", destination: "/tickets?layout=board" },
  { source: "/epics", destination: "/tickets?layout=epics" },
  { source: "/costs", destination: "/reports?tab=costs" },
  // Costs and Highlights moved from the Runs tabs to Reports; the rest of the query carries over.
  { source: "/runs", hasQuery: { key: "tab", value: /^(costs|highlights)$/ }, destination: "/reports" },
  // The Dashboard re-summed the Inbox, Runs and Tickets; what needs you is in the Inbox.
  { source: "/dashboard", destination: "/inbox" },
  // Artifacts are Library's "From projects"; /artifacts/:id stays the document page.
  { source: "/artifacts", destination: "/library?source=projects" },
];

/** Where `url` should redirect to (path, query and hash), or null. */
export function redirectFor(url: URL): string | null {
  const custom = customizationRedirect(url);
  if (custom) return custom;
  const path = url.pathname.length > 1 ? url.pathname.replace(/\/+$/, "") : url.pathname;
  for (const rule of REDIRECTS) {
    if (rule.source !== path) continue;
    if (rule.hasQuery && !rule.hasQuery.value.test(url.searchParams.get(rule.hasQuery.key) ?? "")) continue;
    const dest = new URL(rule.destination, url.origin);
    const own = new Set(dest.searchParams.keys());
    for (const [k, v] of url.searchParams) if (!own.has(k)) dest.searchParams.append(k, v);
    return dest.pathname + dest.search + url.hash;
  }
  return null;
}
