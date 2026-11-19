"use client";

import { HarnessFooter } from "@/components/shell/harness-footer";
import Link from "next/link";
import { HumanAvatar } from "@/components/domain/avatars";
import { Icon } from "@/components/ui/icon";
import { Content, TopBar } from "@/components/shell/topbar";
import { useBootstrap } from "@/lib/api/hooks";
import { useSpaces } from "@/lib/api/space-hooks";
import { cx } from "@/lib/cx";
import type { NavBadge, NavGroup, NavItem } from "@/lib/project-scope";
import { moreLabel, moreSections } from "@/lib/tab-bar";
import { useNavCounts } from "@/lib/use-nav-counts";
import { SpaceTile } from "@/app/(app)/spaces/_components/space-parts";

type Counts = Record<NavBadge, number>;

const heading = "mb-1.5 px-3 text-12 font-medium text-fg-tertiary";
const card = "overflow-hidden rounded-lg border border-border bg-surface";
const row = "flex min-h-[44px] items-center gap-3 px-3 text-14 text-fg hover:bg-hover";

function count(item: NavItem, counts: Counts) {
  return item.badge ? counts[item.badge] : 0;
}

/** The sidebar's badge styles: Wiki's suggestions as a mono number, anything else as an amber count. */
function RowBadge({ item, counts }: { item: NavItem; counts: Counts }) {
  const n = count(item, counts);
  if (n <= 0) return null;
  if (item.badge === "wiki") return <span aria-hidden className="font-mono text-12 text-pill-human-fg">{n}</span>;
  return (
    <span aria-hidden className="grid h-[18px] min-w-[18px] place-items-center rounded-[9px] bg-state-human px-[5px] text-12 font-semibold text-approve-fg">
      {n}
    </span>
  );
}

/** Opens the command menu, which fills the screen below COMPACT. */
function SearchField() {
  return (
    <button
      type="button"
      onClick={() => window.dispatchEvent(new Event("la:search"))}
      className="flex min-h-[44px] w-full items-center gap-2.5 rounded-lg border border-border bg-surface px-3 text-left text-16 text-fg-tertiary hover:bg-hover"
    >
      <Icon name="search" size={16} strokeWidth={1.6} />
      Search
    </button>
  );
}

/** You: the person, with Settings beside them. */
function ProfileRow({ group, counts }: { group: NavGroup; counts: Counts }) {
  const me = useBootstrap().data?.me;
  return (
    <section aria-label={group.label} className={cx(card, "flex items-center gap-3 px-3 py-2")}>
      {me && <HumanAvatar name={me.name} initials={me.initials} color={me.avatar_color} src={me.avatar_url} size={32} label={false} />}
      <span className="min-w-0 flex-1 truncate text-14 font-medium">{me?.name ?? ""}</span>
      {group.items.map((item) => (
        <Link
          key={item.href}
          href={item.href}
          aria-label={moreLabel(item.label, item.badge, counts)}
          title={item.label}
          className="relative grid size-[44px] place-items-center rounded-md text-fg-secondary hover:bg-hover hover:text-fg"
        >
          <Icon name={item.icon} size={18} strokeWidth={1.6} />
          {count(item, counts) > 0 && <span aria-hidden data-testid="more-dot" className="absolute right-2 top-2 size-2 rounded-full bg-state-human" />}
        </Link>
      ))}
    </section>
  );
}

function AppsGrid({ group, counts }: { group: NavGroup; counts: Counts }) {
  return (
    <section aria-labelledby="more-apps">
      <h2 id="more-apps" className={heading}>{group.label}</h2>
      <ul className="grid grid-cols-3 gap-2">
        {group.items.map((item) => (
          <li key={item.href}>
            <Link
              href={item.href}
              aria-label={moreLabel(item.label, item.badge, counts)}
              className="relative flex h-[76px] flex-col items-center justify-center gap-1.5 rounded-[10px] border border-border bg-surface text-12 text-fg-secondary hover:bg-hover hover:text-fg"
            >
              <Icon name={item.icon} size={20} />
              <span className="max-w-full truncate px-1">{item.label}</span>
              <span className="absolute right-1.5 top-1.5"><RowBadge item={item} counts={counts} /></span>
            </Link>
          </li>
        ))}
      </ul>
    </section>
  );
}

function ListGroup({ group, counts }: { group: NavGroup; counts: Counts }) {
  const id = `more-${group.label.toLowerCase()}`;
  return (
    <section aria-labelledby={id}>
      <h2 id={id} className={heading}>{group.label}</h2>
      <ul className={card}>
        {group.items.map((item) => (
          <li key={item.href} className="border-b border-border-subtle last:border-b-0">
            <Link href={item.href} aria-label={moreLabel(item.label, item.badge, counts)} className={row}>
              <Icon name={item.icon} size={16} strokeWidth={1.6} />
              <span className="flex-1">{item.label}</span>
              <RowBadge item={item} counts={counts} />
              <Icon name="chevr" size={12} className="text-fg-tertiary" />
            </Link>
          </li>
        ))}
      </ul>
    </section>
  );
}

function Spaces() {
  const spaces = useSpaces();
  const list = spaces.data?.spaces ?? [];
  return (
    <section aria-labelledby="more-spaces">
      <h2 id="more-spaces" className={heading}>Spaces</h2>
      {spaces.isError ? (
        <p role="alert" className="px-3 text-12 text-pill-blocked-fg">Couldn’t load spaces.</p>
      ) : spaces.data && list.length === 0 ? (
        <p className="px-3 text-14 text-fg-tertiary">No spaces yet.</p>
      ) : (
        <ul className={card}>
          {list.map((s) => (
            <li key={s.id} className="border-b border-border-subtle last:border-b-0">
              <Link href={`/spaces/${s.id}`} className={row}>
                <SpaceTile name={s.name} color={s.color} size={20} />
                <span className="min-w-0 flex-1 truncate">{s.name}</span>
                <span className="text-12 text-fg-tertiary">{s.chat_count}</span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

/**
 * The compact shell's More tab (DESIGN.md §3 Responsive): search, your profile row, then
 * every other NAV_GROUPS page the tab bar has no tab for, with the sidebar's badges, then Spaces.
 */
export default function Page() {
  const counts = useNavCounts();
  // The profile row leads, as in the design; the rest keep the sidebar's order.
  const sections = moreSections().sort((a, b) => Number(b.label === "You") - Number(a.label === "You"));
  return (
    <>
      <TopBar crumbs={[{ label: "More" }]} />
      <Content>
        <div className="flex flex-col gap-6">
          <SearchField />
          {sections.map((g) =>
            g.label === "You" ? (
              <ProfileRow key={g.label} group={g} counts={counts} />
            ) : g.label === "Apps" ? (
              <AppsGrid key={g.label} group={g} counts={counts} />
            ) : (
              <ListGroup key={g.label} group={g} counts={counts} />
            ),
          )}
          <Spaces />
          <section aria-labelledby="more-harnesses">
            <h2 id="more-harnesses" className={heading}>Harnesses</h2>
            <div className={cx(card, "overflow-hidden px-2.5")}>
              <HarnessFooter layout="row" />
            </div>
          </section>
        </div>
      </Content>
    </>
  );
}
