const ROUTE_TITLES: Array<[prefix: string, title: string]> = [
  ["/settings/runner", "Runner environment"],
  ["/settings/projects", "Space settings"],
  ["/settings", "Settings"],
  ["/dev", "Dev workspace"],
  ["/chat", "Chat"],
  ["/work", "Work"],
  ["/inbox", "Inbox"],
  ["/runs", "Runs"],
  ["/tickets/new", "New ticket"],
  ["/tickets", "Tickets"],
  ["/epics", "Epics"],
  ["/knowledge/connect", "Connect Knowledge"],
  ["/knowledge/graph", "Knowledge graph"],
  ["/knowledge", "Knowledge"],
  ["/library", "Library"],
  ["/customization", "Customization"],
  ["/agents", "Agent"],
  ["/workflows", "Workflows"],
  ["/scheduled", "Scheduled"],
  ["/reports", "Reports"],
  ["/plans", "Plans"],
  ["/learn", "Learning"],
  ["/spaces/new", "New space"],
  ["/spaces", "Spaces"],
  ["/setup", "Setup"],
  ["/apps/designs", "Designs"],
  ["/apps/docs", "Docs"],
  ["/apps/slides", "Slides"],
  ["/apps", "Apps"],
  ["/artifacts", "Artifact"],
  ["/more", "More"],
];

export function routeFallbackTitle(pathname: string): string {
  const clean = pathname.split("?")[0]?.split("#")[0] ?? "/";
  if (clean === "/") return "Home";
  for (const [prefix, title] of ROUTE_TITLES) {
    if (clean === prefix || clean.startsWith(`${prefix}/`)) return title;
  }
  return "";
}

export function cleanHeadingTitle(raw: string | null | undefined): string {
  if (!raw) return "";
  const normalized = raw.replace(/\s+/g, " ").trim();
  if (!normalized || normalized === "Vesper" || /^loading[.…]*$/i.test(normalized)) {
    return "";
  }
  return normalized.length > 80 ? `${normalized.slice(0, 77)}…` : normalized;
}

export function formatDocumentTitle(pageTitle: string | null | undefined): string {
  const clean = cleanHeadingTitle(pageTitle);
  if (!clean) return "Vesper";
  if (clean.endsWith("· Vesper")) return clean;
  return `${clean} · Vesper`;
}
