"use client";

import Link from "next/link";
import { DropdownMenu } from "radix-ui";
import { useState } from "react";
import { generateHTML } from "@tiptap/core";
import { ApiError } from "@/lib/api/client";
import { docPrintHref, downloadFile, usePromoteDocToWiki, useSaveDocToLibrary } from "@/lib/api/docs-hooks";
import { wikiHref } from "@/lib/wikilinks";
import { docExtensions, parseDoc } from "@/lib/doc-markdown";
import { toDocx } from "@/lib/doc-docx";
import { floatPanel } from "@/components/domain/pickers";
import { Button } from "@/components/ui/button";
import { confirmAction } from "@/components/ui/confirm";

const item = "flex cursor-pointer select-none flex-col rounded-md px-2.5 py-1.5 text-13 text-fg outline-none data-[highlighted]:bg-hover";
const detail = "text-11 text-fg-tertiary";

export type ExportNotice = { tone: "ok" | "error"; text: string; href?: string };

/**
 * Every way a document leaves Vesper, as functions, with the notice each one leaves. `current` saves
 * pending edits first and returns the text as saved, so an export never misses the last few words.
 * The web's Share menu and the Mac app's toolbar menu both run these.
 */
export function useDocExports({ id, title, current }: { id: string; title: string; current: () => Promise<string> }) {
  const library = useSaveDocToLibrary(id);
  const promote = usePromoteDocToWiki(id);
  const [notice, setNotice] = useState<ExportNotice>();
  const say = (n: ExportNotice) => {
    setNotice(n);
    setTimeout(() => setNotice((x) => (x === n ? undefined : x)), 4000);
  };
  const attempt = (what: string, fn: () => Promise<ExportNotice | void>) => () =>
    void fn()
      .then((n) => n && say(n))
      .catch((e: unknown) => say({ tone: "error", text: `${what} failed: ${e instanceof Error ? e.message : "try again"}` }));

  const word = attempt("Word export", async () => {
    const [md, docx] = await Promise.all([current(), import("docx")]);
    downloadFile(title, "docx", await docx.Packer.toBlob(toDocx(docx, parseDoc(md), title)));
  });
  const markdown = attempt("Markdown export", async () => downloadFile(title, "md", new Blob([await current()], { type: "text/markdown;charset=utf-8" })));
  const pdf = attempt("PDF export", async () => {
    await current();
    window.open(docPrintHref(id), "_blank", "noopener");
  });
  // Rich text pastes into mail, Google Docs or Slack with its formatting; the Markdown goes along as plain text.
  const copy = attempt("Copy", async () => {
    const md = await current();
    const html = generateHTML(parseDoc(md), docExtensions());
    await navigator.clipboard.write([new ClipboardItem({ "text/html": new Blob([html], { type: "text/html" }), "text/plain": new Blob([md], { type: "text/plain" }) })]);
    return { tone: "ok", text: "Copied with formatting" };
  });
  const save = attempt("Saving to the Library", async () => {
    await current();
    await library.mutateAsync();
    return { tone: "ok", text: "Saved to your Library", href: "/library" };
  });

  // A copy for agents to read, so it asks before replacing a page that exists.
  const publish = attempt("Publishing to the wiki", async () => {
    await current();
    const done = (r: { path: string }): ExportNotice => ({ tone: "ok", text: `Published to the wiki as ${r.path}`, href: wikiHref(r.path) });
    try {
      return done(await promote.mutateAsync(false));
    } catch (e) {
      if (!(e instanceof ApiError && e.status === 409) || !await confirmAction({ title: "Replace the wiki page?", body: `${e.message} Replace it with this version?`, confirmLabel: "Replace" })) throw e;
      return done(await promote.mutateAsync(true));
    }
  });

  return { notice, pdf, word, markdown, copy, save, publish, libraryPending: library.isPending, promotePending: promote.isPending };
}

export type DocExports = ReturnType<typeof useDocExports>;

/** The web's Share / Export menu over `exports`. `trigger` renames its button, e.g. the editor header's Share ▾. */
export function ExportMenu({ exports: x, trigger }: { exports: DocExports; trigger?: string }) {
  const { notice, pdf, word, markdown, copy, save, publish } = x;
  const library = { isPending: x.libraryPending };
  const promote = { isPending: x.promotePending };
  return (
    <div className="flex items-center gap-2">
      {notice && (
        <span role={notice.tone === "error" ? "alert" : "status"} className={notice.tone === "error" ? "text-12 text-pill-blocked-fg" : "text-12 text-fg-secondary"}>
          {notice.text}
          {notice.href && (
            <>
              {" · "}
              <Link href={notice.href} className="text-accent hover:underline">Open</Link>
            </>
          )}
        </span>
      )}
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          {trigger ? (
            <Button variant="primary">
              {trigger} <span aria-hidden>▾</span>
            </Button>
          ) : (
            <Button variant="secondary" icon="download">Export</Button>
          )}
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content align="end" sideOffset={6} className={`${floatPanel} z-50 w-[250px]`}>
            <DropdownMenu.Item className={item} onSelect={pdf}>PDF<span className={detail}>Opens the print dialog</span></DropdownMenu.Item>
            <DropdownMenu.Item className={item} onSelect={word}>Word (.docx)<span className={detail}>Opens in Word, Pages or Google Docs</span></DropdownMenu.Item>
            <DropdownMenu.Item className={item} onSelect={markdown}>Markdown (.md)<span className={detail}>The document as written</span></DropdownMenu.Item>
            <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />
            <DropdownMenu.Item className={item} onSelect={copy}>Copy as rich text<span className={detail}>Paste with formatting anywhere</span></DropdownMenu.Item>
            <DropdownMenu.Item className={item} disabled={library.isPending} onSelect={save}>Save to Library<span className={detail}>Keeps a copy as it is now</span></DropdownMenu.Item>
            <DropdownMenu.Item className={item} disabled={promote.isPending} onSelect={publish}>Promote to wiki<span className={detail}>Shares a copy with agents</span></DropdownMenu.Item>
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
    </div>
  );
}
