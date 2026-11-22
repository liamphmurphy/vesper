"use client";

import { useRouter } from "next/navigation";
import { useMemo, useRef, useState, type PointerEvent, type WheelEvent } from "react";
import { cx } from "@/lib/cx";
import { bounds, layoutGraph } from "@/lib/knowledge-graph";
import { pageHref } from "@/lib/knowledge";
import { useNetwork } from "@/lib/api/knowledge-hooks";
import { Icon } from "@/components/ui/icon";
import { EmptyState, Skeleton } from "@/components/ui/primitives";
import { StatusBar } from "./kit";

const PALETTE = ["#9B8CFF", "#3FC1B0", "#F0BF4C", "#4EA7FC", "#F48A98", "#F59E5B", "#6FCF97", "#C89BFF"];

/** Every page and link you can see, laid out by force, coloured by top folder; click a page to open it. */
export function GraphScreen() {
  const router = useRouter();
  const [agent, setAgent] = useState(false);
  const [orphans, setOrphans] = useState(true);
  const [search, setSearch] = useState("");
  const [hover, setHover] = useState<string>();
  const net = useNetwork(agent);

  const { placed, edges, groups, byId, unresolved } = useMemo(() => {
    const data = net.data ?? { nodes: [], links: [] };
    const links = data.links.filter((l): l is { source: string; target: string } => !!l.target);
    const linked = new Set(links.flatMap((l) => [l.source, l.target]));
    const nodes = data.nodes.filter((n) => orphans || linked.has(n.id)).map((n) => ({ ...n, group: n.path.includes("/") ? n.path.split("/")[0] : "Top level" }));
    const count = new Map<string, number>();
    for (const n of nodes) count.set(n.group, (count.get(n.group) ?? 0) + 1);
    const groups = [...count.entries()].sort((a, b) => b[1] - a[1]).slice(0, PALETTE.length).map(([g], i) => ({ name: g, color: PALETTE[i] }));
    const placed = layoutGraph(nodes, links);
    const byId = new Map(nodes.map((n) => [n.id, n]));
    return { placed, edges: links, groups, byId, unresolved: data.links.filter((l) => l.unresolved).length };
  }, [net.data, orphans]);

  const at = useMemo(() => new Map(placed.map((p) => [p.id, p])), [placed]);
  const colorOf = (group: string) => groups.find((g) => g.name === group)?.color ?? "#5E5B6E";
  const neighbours = useMemo(() => {
    if (!hover) return undefined;
    return new Set([hover, ...edges.filter((e) => e.source === hover || e.target === hover).flatMap((e) => [e.source, e.target])]);
  }, [hover, edges]);
  const match = search.trim().toLowerCase();

  // Pan and zoom in viewBox units.
  const box = bounds(placed);
  const [view, setView] = useState<{ x: number; y: number; s: number }>({ x: 0, y: 0, s: 1 });
  const drag = useRef<{ x: number; y: number } | null>(null);
  const svg = useRef<SVGSVGElement>(null);
  const onWheel = (e: WheelEvent) => setView((v) => ({ ...v, s: Math.min(6, Math.max(0.3, v.s * (e.deltaY > 0 ? 0.9 : 1.1))) }));
  const onDown = (e: PointerEvent) => {
    if ((e.target as Element).closest("[data-node]")) return;
    drag.current = { x: e.clientX, y: e.clientY };
    (e.currentTarget as Element).setPointerCapture(e.pointerId);
  };
  const onMove = (e: PointerEvent) => {
    if (!drag.current || !svg.current) return;
    const scale = box.w / view.s / svg.current.clientWidth;
    setView((v) => ({ ...v, x: v.x - (e.clientX - drag.current!.x) * scale, y: v.y - (e.clientY - drag.current!.y) * scale }));
    drag.current = { x: e.clientX, y: e.clientY };
  };
  const w = box.w / view.s;
  const h = box.h / view.s;
  const vb = `${box.x + (box.w - w) / 2 + view.x} ${box.y + (box.h - h) / 2 + view.y} ${w} ${h}`;
  const labelAll = placed.length < 60 || view.s > 2;
  // Sizes are in graph units; keep labels and dots about the same on screen at any vault size and zoom.
  const unit = Math.max(w, h * 1.6) / 1200;

  return (
    <>
      <div className="relative min-h-0 flex-1 bg-surface-sunken">
        {net.isPending ? (
          <div className="p-8">
            <Skeleton className="h-full min-h-[300px] w-full" />
          </div>
        ) : placed.length === 0 ? (
          <EmptyState icon="graph" title="No pages to draw yet">Pages and the links between them appear here as you write.</EmptyState>
        ) : (
          <svg
            ref={svg}
            role="img"
            aria-label={`Graph of ${placed.length} pages`}
            viewBox={vb}
            className="h-full w-full cursor-grab touch-none select-none active:cursor-grabbing"
            onWheel={onWheel}
            onPointerDown={onDown}
            onPointerMove={onMove}
            onPointerUp={() => (drag.current = null)}
          >
            <g>
              {edges.map((e, i) => {
                const a = at.get(e.source);
                const b = at.get(e.target);
                if (!a || !b) return null;
                const lit = neighbours && neighbours.has(e.source) && neighbours.has(e.target) && (e.source === hover || e.target === hover);
                return <line key={i} x1={a.x} y1={a.y} x2={b.x} y2={b.y} stroke={lit ? "var(--accent)" : "var(--border-strong)"} strokeWidth={(lit ? 1.6 : 1) * unit} opacity={neighbours && !lit ? 0.25 : 1} />;
              })}
            </g>
            <g>
              {placed.map((p) => {
                const n = byId.get(p.id)!;
                const r = Math.min(12, 3.5 + Math.sqrt(p.degree) * 1.6) * unit;
                const dim = (neighbours && !neighbours.has(p.id)) || (match && !n.title.toLowerCase().includes(match));
                const show = labelAll || p.degree >= 6 || p.id === hover || (match && !dim);
                return (
                  <g
                    key={p.id}
                    data-node
                    className="cursor-pointer"
                    opacity={dim ? 0.2 : 1}
                    onPointerEnter={() => setHover(p.id)}
                    onPointerLeave={() => setHover(undefined)}
                    onClick={() => router.push(pageHref(p.id, n.title))}
                  >
                    <title>{n.path}</title>
                    <circle cx={p.x} cy={p.y} r={r} fill={p.degree ? colorOf(n.group) : "var(--text-tertiary)"} stroke={p.id === hover ? "var(--text)" : "none"} strokeWidth={1.5 * unit} />
                    {show && (
                      <text x={p.x} y={p.y + r + 11 * unit} textAnchor="middle" fontSize={10.5 * unit} fill={p.id === hover ? "var(--text)" : "var(--text-secondary)"} fontWeight={p.id === hover ? 600 : 400}>
                        {n.title.length > 28 ? `${n.title.slice(0, 27)}…` : n.title}
                      </text>
                    )}
                  </g>
                );
              })}
            </g>
          </svg>
        )}
        <div className="absolute right-4 top-4 w-[260px] rounded-xl border border-border-strong bg-surface-raised p-4 text-13 shadow-[var(--shadow-float)]">
          <p className="mb-3 flex items-center gap-2 font-semibold text-fg">
            <Icon name="sliders" size={14} /> Filters
          </p>
          <label className="mb-3 flex h-8 items-center gap-2 rounded-md border border-border-subtle bg-surface-sunken px-2.5 text-fg-tertiary">
            <Icon name="search" size={13} />
            <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Find a page…" aria-label="Find a page" className="flex-1 bg-transparent text-12 text-fg outline-none" />
          </label>
          <Toggle label="Orphans" on={orphans} onChange={setOrphans} />
          <Toggle label="Agent knowledge" on={agent} onChange={setAgent} />
          <p className="mb-2 mt-3 border-t border-border-subtle pt-3 text-12 font-semibold text-fg">Groups</p>
          <ul className="space-y-1.5">
            {groups.map((g) => (
              <li key={g.name} className="flex items-center gap-2 text-12 text-fg-2">
                <span className="size-2.5 rounded-full" style={{ background: g.color }} />
                path:{g.name}
              </li>
            ))}
          </ul>
          <p className="mt-3 text-11 leading-relaxed text-fg-tertiary">Scroll to zoom, drag to pan. Private pages never show in a run&apos;s graph.</p>
        </div>
      </div>
      <StatusBar left={`${placed.length.toLocaleString()} pages · ${edges.length.toLocaleString()} links · ${unresolved} unresolved`} right={agent ? "Including agent knowledge" : "Graph of your knowledge"} />
    </>
  );
}

function Toggle({ label, on, onChange }: { label: string; on: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="flex h-8 items-center justify-between text-fg-2">
      {label}
      <button role="switch" aria-checked={on} aria-label={label} onClick={() => onChange(!on)} className={cx("relative h-5 w-9 rounded-full transition-colors", on ? "bg-accent" : "bg-border-strong")}>
        <span className={cx("absolute top-0.5 size-4 rounded-full bg-white transition-all", on ? "left-[18px]" : "left-0.5")} />
      </button>
    </label>
  );
}
