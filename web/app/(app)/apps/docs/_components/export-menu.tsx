"use client";

import { useState } from "react";
import { generateHTML } from "@tiptap/core";
import { ApiError } from "@/lib/api/client";
import { docPrintHref, downloadFile, usePromoteDocToWiki, useSaveDocToLibrary } from "@/lib/api/docs-hooks";
import { wikiHref } from "@/lib/wikilinks";
import { docExtensions, parseDoc } from "@/lib/doc-markdown";
import { toDocx } from "@/lib/doc-docx";
import { confirmAction } from "@/components/ui/confirm";

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
