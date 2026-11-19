"use client";

import { Dialog } from "radix-ui";
import { useCallback, useRef, useState } from "react";
import { downloadFile } from "@/lib/api/docs-hooks";
import { useSaveDeckExport } from "@/lib/api/slides-hooks";
import { measure } from "@/lib/slides/fonts";
import { layoutSlide } from "@/lib/slides/layout";
import { SlideSvg } from "@/lib/slides/render";
import { slideTitle, type Deck } from "@/lib/slides/schema";
import { Button } from "@/components/ui/button";

export type DeckExportNotice = { tone: "ok" | "error" | "busy"; text: string };
type Format = "pdf" | "pptx";
type Target = "download" | "library";

/**
 * Every way a deck leaves Vesper (mockup 5/6), as functions. `current` saves pending edits
 * first and returns the deck as saved, so an export never misses the last
 * change. Both formats are built in the browser and downloaded as files.
 * The web's Share ▾ and the Mac app's toolbar menu both run `start`.
 */
export function useDeckExport({ deckId, title, current, assetUrl }: { deckId: string; title: string; current: () => Promise<{ deck: Deck; seq: number }>; assetUrl: (id: string) => string }) {
  const [notice, setNotice] = useState<DeckExportNotice>();
  const save = useSaveDeckExport(deckId);
  const [preflight, setPreflight] = useState<{ format: Format; to: Target; deck: Deck; slides: { n: number; id: string; title: string }[] }>();
  const abort = useRef<AbortController | null>(null);
  const say = (n: DeckExportNotice) => {
    setNotice(n);
    if (n.tone !== "busy") setTimeout(() => setNotice((x) => (x === n ? undefined : x)), 6000);
  };

  const build = async (format: Format, deck: Deck, to: Target) => {
    setPreflight(undefined);
    const ctl = new AbortController();
    abort.current = ctl;
    const label = format === "pdf" ? "PDF" : "PowerPoint";
    say({ tone: "busy", text: `Building ${label}…` });
    try {
      const exp = await import("@/lib/slides/export");
      const blob = format === "pdf" ? await exp.deckToPdf(deck, assetUrl, (done, total) => setNotice({ tone: "busy", text: `Building PDF… slide ${done} of ${total}` }), ctl.signal) : await exp.deckToPptx(deck, assetUrl);
      if (ctl.signal.aborted) return;
      if (to === "library") {
        const name = `${title.replace(/[\\/:*?"<>|]+/g, " ").trim() || "deck"}.${format}`;
        await save.mutateAsync(new File([blob], name, { type: blob.type }));
        say({ tone: "ok", text: `Saved “${name}” to your Library` });
      } else {
        downloadFile(title, format, blob);
        say({ tone: "ok", text: `Downloaded “${title}.${format}”` });
      }
    } catch (e) {
      if (ctl.signal.aborted) return say({ tone: "ok", text: "Export cancelled" });
      say({ tone: "error", text: `${to === "library" ? `Couldn’t save the ${label} to your Library` : `${label} export failed`}: ${e instanceof Error ? e.message : "try again"}` });
    } finally {
      if (abort.current === ctl) abort.current = null;
    }
  };

  const start = (format: Format, to: Target = "download") => async () => {
    try {
      const { deck } = await current();
      // Preflight: list slides whose text runs past its box before exporting them that way.
      const slides = deck.slides.flatMap((s, i) => (!s.hidden && layoutSlide(deck, s, measure).overflow.size ? [{ n: i + 1, id: s.id, title: slideTitle(s) }] : []));
      if (slides.length) setPreflight({ format, to, deck, slides });
      else await build(format, deck, to);
    } catch (e) {
      say({ tone: "error", text: `Couldn't save before exporting: ${e instanceof Error ? e.message : "try again"}` });
    }
  };

  const cancel = useCallback(() => abort.current?.abort(), []);
  return { notice, preflight, setPreflight, start, build, cancel };
}

export type DeckExport = ReturnType<typeof useDeckExport>;

/** The dialog that stops an export whose text runs past its slide's box, to ask. */
export function PreflightDialog({ exp, assetUrl, fontsReady }: { exp: DeckExport; assetUrl: (id: string) => string; fontsReady: boolean }) {
  const { preflight, setPreflight, build } = exp;
  return (
    <>
      <Dialog.Root open={!!preflight} onOpenChange={(o) => !o && setPreflight(undefined)}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content className="motion-dialog fixed left-1/2 top-[14vh] z-50 w-[min(560px,calc(100%-32px))] -translate-x-1/2 overflow-hidden rounded-xl border border-border-float bg-surface-raised shadow-[var(--shadow-float)] outline-none">
          <div className="p-5">
            <Dialog.Title className="text-16 font-semibold text-fg">Export {preflight?.format === "pdf" ? "PDF" : "PowerPoint"} with text that doesn’t fit?</Dialog.Title>
            <Dialog.Description className="mt-2 text-13 text-fg-secondary">
              {preflight?.slides.length === 1 ? "One slide has" : `${preflight?.slides.length} slides have`} text that runs past its box. The export shows it exactly as the editor does: the extra lines spill out, and any past the page edge are cut off.
            </Dialog.Description>
            <ul className="mt-3 flex max-h-[200px] flex-col gap-2 overflow-y-auto">
              {preflight?.slides.map((s) => (
                <li key={s.id} className="flex items-center gap-3 rounded-lg border border-border-subtle bg-surface-sunken p-1.5">
                  <span className="block w-[60px] overflow-hidden rounded-[3px] border border-border">
                    <SlideSvg deck={preflight.deck} slide={preflight.deck.slides[s.n - 1]} assetUrl={assetUrl} fontsReady={fontsReady} showOverflow className="block aspect-video w-full" />
                  </span>
                  <span className="text-13 text-fg-2">Slide {s.n} · {s.title}</span>
                </li>
              ))}
            </ul>
          </div>
          <div className="flex items-center justify-between gap-2 border-t border-track bg-surface-sunken px-5 py-3">
            <span className="text-12 text-fg-tertiary">Esc cancels</span>
            <div className="flex gap-2">
              <Dialog.Close asChild>
                <Button variant="outline">Go back and fix</Button>
              </Dialog.Close>
              <Button variant="primary" autoFocus onClick={() => preflight && void build(preflight.format, preflight.deck, preflight.to)}>
                Export anyway
              </Button>
            </div>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
    </>
  );
}
