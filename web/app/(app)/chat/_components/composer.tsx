"use client";

import { Fragment, useRef, useState, type ReactNode, type RefObject } from "react";
import type { Schemas } from "@/lib/api/client";
import { addChip, chipFromTarget, removeChip, type Chip } from "@/lib/chat-context";
import { CHAT_COMMANDS, commandMenu, literalBody, parseCommand } from "@/lib/chat-commands";
import { insertMention, mentionQuery, mentionSuggestions } from "@/lib/persona-ui";
import { cx } from "@/lib/cx";
import type { ComposerOption, ComposerOptionId } from "@/lib/composer-options";
import { LinkEditor } from "@/components/domain/link-editor";
import { acceptTarget, AddContext, ChipList, type CreateWith } from "./context-chips";
import { AttachButton, AttachmentChips, type useAttachments } from "./attachments";
import { ComposerHints, composerFrameFor, composerIconButton, composerInput, SendButton, type SendTone } from "./reply-tools";
import { PersonaAvatar, PersonaName, personaLook } from "./persona";
import { ComposerMenu, ComposerSheet } from "./composer-sheet";
import { useCompact } from "@/lib/viewport";
import { detectLanguage, isBigPaste, messageWithSnippets, offerAsSnippet, withoutPaste } from "@/lib/snippets";
import { Icon } from "@/components/ui/icon";
import { CodeButton, newSnippetDraft, PasteOffer, SnippetBubble, SnippetChips, snippetFile, type PasteOfferState, type SnippetDraft, type Snippets } from "./snippets";

/** A / command's action; a returned string is why it couldn't run. */
export type CommandRun = () => string | void;

export type ComposerCommands = {
  repository?: (arg: string) => string | void;
  compare?: (arg: string) => string | void;
  /** The commands that take nothing after them: new, memory, stop. */
  plain: Record<string, CommandRun>;
  /** What a command that takes something offers, e.g. the models for /model. */
  options: (name: string) => { name: string; run: CommandRun }[];
  hasWorkflows: boolean;
  /** The commands whose argument is text to send (/aside, /queue). */
  free?: Record<string, (text: string) => string | void>;
};

/**
 * The one message box, for a conversation and for the welcome before its first message:
 * [[ context and Add context, files, code snippets, @ persona mentions, / commands. Its controls come from
 * the caller's composerOptions list: the "options" ones on the left, the "actions" ones on the
 * right before the caller's actions (Stop) and Send; controls holds each one's control, while
 * Add context, Attach and Code are the composer's own. Its parent owns the draft, chips, files and snippets so
 * it can send them, clear them and seed them from links. The row under the box is + (a popover on desktop,
 * a sheet below COMPACT, listing the options), the modes that are on, the model, the actions and Send.
 */
export function Composer({
  text,
  onText,
  inputRef,
  files,
  snippets,
  chips,
  onChips,
  onSubmit,
  commands,
  personas,
  inChat,
  placeholder,
  disabled,
  rows = 1,
  options,
  controls = {},
  actions,
  send,
  onCycle,
  hints,
  create,
}: {
  text: string;
  onText: (text: string) => void;
  inputRef: RefObject<HTMLTextAreaElement | null>;
  files: ReturnType<typeof useAttachments>;
  /** Code and Markdown snippets, sent as fenced blocks after the text. */
  snippets: Snippets;
  chips: Chip[];
  onChips: (update: (chips: Chip[]) => Chip[]) => void;
  /** A message that isn't a command, with a leading // already reduced to / and the snippets' blocks after it. */
  onSubmit: (body: string) => void;
  commands: ComposerCommands;
  /** Who @ can mention; inChat marks the ones already in the conversation. */
  personas: Schemas["Persona"][];
  inChat: (personaId: string) => boolean;
  placeholder: string;
  disabled: boolean;
  rows?: number;
  /** composerOptions(…): which controls show, in order. */
  options: ComposerOption[];
  controls?: Partial<Record<ComposerOptionId, ReactNode>>;
  /** Shown after the option actions, before Send (Stop). */
  actions?: ReactNode;
  send: { label: string; disabled: boolean; title?: string; tone?: SendTone };
  /** Tab in a draft with no menu open: the caller switches how Send sends (back for Shift+Tab). */
  onCycle?: (back: boolean) => void;
  /** Replaces the usual line of hints under the box. */
  hints?: ReactNode;
  /** The + menu's "Create with {persona}" section. */
  create?: CreateWith;
}) {
  // The @mention being typed, and which suggestion is highlighted.
  const [mention, setMention] = useState<{ start: number; query: string } | null>(null);
  const [mentionActive, setMentionActive] = useState(0);
  // The / command menu: which row is highlighted, whether Esc closed it, and why the last command didn't run.
  const [commandActive, setCommandActive] = useState(0);
  const [commandDismissed, setCommandDismissed] = useState(false);
  const [commandError, setCommandError] = useState<string | null>(null);
  const compact = useCompact();
  const [sheet, setSheet] = useState(false);

  // The snippet bubble's draft (open while set), and the last paste into the message box worth offering as a snippet or file.
  const [snippetDraft, setSnippetDraft] = useState<SnippetDraft | null>(null);
  const [paste, setPaste] = useState<PasteOfferState | null>(null);
  const frame = useRef<HTMLDivElement>(null);
  const pastedFiles = useRef(0);
  const offer = paste && text.includes(paste.text) ? paste : null;
  const saveSnippet = (d: SnippetDraft) => {
    if (d.key === undefined) snippets.add(d.text, d.lang);
    else snippets.update(d.key, d.text, d.lang);
    setSnippetDraft(null);
  };
  const attachPasted = (pasted: string, lang: string) => files.add([snippetFile(pasted, lang, ++pastedFiles.current)]);
  const takeBackPaste = (o: PasteOfferState) => {
    const rest = withoutPaste(text, o);
    if (rest !== null) onText(rest);
    setPaste(null);
    inputRef.current?.focus();
  };

  const attach = (t: Parameters<typeof chipFromTarget>[0]) => {
    const chip = chipFromTarget(t);
    if (chip) onChips((cs) => addChip(cs, chip));
  };
  const menu = commandDismissed ? null : commandMenu(text);
  const suggestions = mention && !menu ? mentionSuggestions(personas, mention.query) : [];
  const syncMention = (value: string) => {
    const el = inputRef.current;
    const next = el ? mentionQuery(value, el.selectionStart) : null;
    if (next?.query !== mention?.query) setMentionActive(0);
    setMention(next);
  };
  const pickMention = (name: string) => {
    const el = inputRef.current;
    if (!el || !mention) return;
    const next = insertMention(text, mention.start, el.selectionStart, name);
    onText(next.text);
    setMention(null);
    requestAnimationFrame(() => {
      el.focus();
      el.setSelectionRange(next.caret, next.caret);
    });
  };

  const runCommand = (run: CommandRun) => {
    const problem = run();
    setCommandError(problem || null);
    if (!problem) onText("");
  };
  const commandItems: { name: string; label: string; hint?: string; choose: () => void }[] = !menu
    ? []
    : menu.stage === "arg"
      ? mentionSuggestions(commands.options(menu.name), menu.query, 8).map((o) => ({ name: o.name, label: o.name, choose: () => runCommand(o.run) }))
      : mentionSuggestions(CHAT_COMMANDS, menu.query, CHAT_COMMANDS.length).map((cmd) => ({
          name: cmd.name,
          label: `/${cmd.name}`,
          hint: cmd.hint,
          choose: () => {
            setCommandActive(0);
            if (cmd.args) onText(`/${cmd.name} `);
            else runCommand(commands.plain[cmd.name]);
          },
        }));
  // A finished command, typed in full or with the menu closed.
  const runTyped = ({ name, arg }: { name: string; arg: string }) => {
    const command = CHAT_COMMANDS.find((x) => x.name === name);
    if (!command) return setCommandError(`Unknown command /${name}. Start with // to send it as a message.`);
    if (name === "repo" && commands.repository) return runCommand(() => commands.repository!(arg));
    if (name === "compare") {
      if (!commands.compare) return setCommandError("/compare works once the conversation has started.");
      return runCommand(() => commands.compare!(arg));
    }
    const free = command.free ? commands.free?.[name] : undefined;
    if (free) return arg ? runCommand(() => free(arg)) : setCommandError(`Say ${name === "design" ? "what to design" : "what to send"}: /${name} <${command.args}>`);
    if (command.free) return setCommandError(`/${name} works once the conversation has started.`);
    if (!command.args) return arg ? setCommandError(`/${name} doesn’t take anything after it.`) : runCommand(commands.plain[name]);
    if (name === "workflow" && !commands.hasWorkflows) return setCommandError("You have no published workflows yet. Build one under Workflows.");
    if (!arg) return setCommandError(`Say which ${command.args}: /${name} <${command.args}>`);
    const match = mentionSuggestions(commands.options(name), arg)[0];
    if (!match) return setCommandError(`No ${command.args} matches “${arg}”.`);
    runCommand(match.run);
  };
  const control = (o: ComposerOption) =>
    o.id === "context" ? (
      <AddContext key={o.id} onPick={attach} onClosed={() => inputRef.current?.focus()} disabled={disabled} compact create={create} />
    ) : o.id === "attach" ? (
      <AttachButton key={o.id} onFiles={files.add} disabled={disabled} compact />
    ) : o.id === "code" ? (
      <CodeButton key={o.id} open={!!snippetDraft} onToggle={() => setSnippetDraft((d) => (d ? null : newSnippetDraft()))} disabled={disabled} count={snippets.items.length} />
    ) : (
      <Fragment key={o.id}>{controls[o.id]}</Fragment>
    );
  // In the sheet, picking context or files is done with it, so the sheet closes too.
  const sheetControl = (o: ComposerOption) =>
    o.id === "context" ? (
      <AddContext
        onPick={(t) => {
          attach(t);
          setSheet(false);
        }}
        onClosed={() => inputRef.current?.focus()}
        disabled={disabled}
        compact
        create={create}
      />
    ) : o.id === "attach" ? (
      <AttachButton
        onFiles={(f) => {
          files.add(f);
          setSheet(false);
        }}
        disabled={disabled}
        compact
      />
    ) : o.id === "code" ? (
      <button
        type="button"
        aria-label="Add code or Markdown"
        disabled={disabled}
        onClick={() => {
          setSheet(false);
          setSnippetDraft(newSnippetDraft());
        }}
        className={composerIconButton}
      >
        <Icon name="code" size={14} />
      </button>
    ) : (
      controls[o.id]
    );
  const submitComposer = () => {
    const command = parseCommand(text);
    if (command) runTyped(command);
    else onSubmit(messageWithSnippets(literalBody(text), snippets.items));
  };

  return (
    <>
      {commandError && (
        <p role="alert" data-testid="command-error" className="text-13 text-pill-blocked-fg">
          {commandError}
        </p>
      )}
      <form
        data-dock-avoid=""
        onPaste={(e) => {
          files.onPaste(e);
          // Only the message box: a paste into the snippet bubble stays in the bubble.
          if (e.defaultPrevented || e.target !== inputRef.current) return;
          const pasted = e.clipboardData.getData("text/plain").replace(/\r\n?/g, "\n");
          const big = isBigPaste(pasted);
          const lang = big ? detectLanguage(pasted) : offerAsSnippet(pasted);
          setPaste(lang ? { text: pasted, start: inputRef.current.selectionStart, lang, big } : null);
        }}
        onSubmit={(e) => {
          e.preventDefault();
          submitComposer();
        }}
        className="flex flex-col gap-2"
      >
        <AttachmentChips attachments={files} />
        <ChipList chips={chips} onRemove={(k) => onChips((cs) => removeChip(cs, k))} disabled={disabled} />
        <SnippetChips snippets={snippets} disabled={disabled} onEdit={(x) => setSnippetDraft({ key: x.key, text: x.text, lang: x.lang, picked: true })} />
        {offer && (
          <PasteOffer
            offer={offer}
            onSnippet={() => {
              takeBackPaste(offer);
              snippets.add(offer.text, offer.lang);
            }}
            onAttach={() => {
              takeBackPaste(offer);
              attachPasted(offer.text, offer.lang);
            }}
            onDismiss={() => {
              setPaste(null);
              inputRef.current?.focus();
            }}
          />
        )}
        <SnippetBubble
          anchor={frame}
          draft={snippetDraft}
          onDraft={setSnippetDraft}
          onSave={saveSnippet}
          onAttach={(d) => {
            attachPasted(d.text, d.lang);
            if (d.key !== undefined) snippets.remove(d.key);
            setSnippetDraft(null);
          }}
          onClosed={() => inputRef.current?.focus()}
        />
        <div ref={frame} data-composer-frame="" className={composerFrameFor(send.tone)}>
          <div className="relative">
            {commandItems.length > 0 && (
              <ul
                role="listbox"
                aria-label="Commands"
                data-testid="command-suggestions"
                className="absolute bottom-full left-2 z-10 mb-1 flex min-w-[280px] flex-col rounded-lg border border-border bg-surface-raised p-1 shadow-lg"
              >
                {commandItems.map((item, i) => (
                  <li key={item.name} role="option" aria-selected={i === commandActive}>
                    <button
                      type="button"
                      onMouseDown={(e) => e.preventDefault()}
                      onMouseEnter={() => setCommandActive(i)}
                      onClick={item.choose}
                      className={cx("flex w-full items-center gap-3 rounded-md px-2 py-1.5 text-left text-13", i === commandActive && "bg-selected")}
                    >
                      <span className="flex-none">{item.label}</span>
                      {item.hint && <span className="ml-auto truncate text-12 text-fg-tertiary">{item.hint}</span>}
                    </button>
                  </li>
                ))}
              </ul>
            )}
            {suggestions.length > 0 && (
              <ul
                role="listbox"
                aria-label="Mention a persona"
                data-testid="mention-suggestions"
                className="absolute bottom-full left-2 z-10 mb-1 flex min-w-[200px] flex-col rounded-lg border border-border bg-surface-raised p-1 shadow-lg"
              >
                {suggestions.map((p, i) => (
                  <li key={p.id} role="option" aria-selected={i === mentionActive}>
                    <button
                      type="button"
                      onMouseDown={(e) => e.preventDefault()}
                      onMouseEnter={() => setMentionActive(i)}
                      onClick={() => pickMention(p.name)}
                      className={cx("flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-13", i === mentionActive && "bg-selected")}
                    >
                      <PersonaAvatar persona={personaLook(p)} size={18} />
                      <PersonaName persona={personaLook(p)} />
                      {inChat(p.id) && <span className="ml-auto text-12 text-fg-tertiary">in chat</span>}
                    </button>
                  </li>
                ))}
              </ul>
            )}
            <LinkEditor
              inputRef={(el) => {
                inputRef.current = el;
              }}
              mono={false}
              aria-label="Message"
              className={composerInput}
              rows={rows}
              value={text}
              onChange={(v) => {
                onText(v);
                syncMention(v);
                setCommandActive(0);
                setCommandDismissed(false);
                setCommandError(null);
              }}
              onBlur={() =>
                setTimeout(() => {
                  if (document.activeElement === inputRef.current) return;
                  setMention(null);
                  setCommandDismissed(true);
                }, 120)
              }
              onPick={attach}
              accept={acceptTarget}
              disabled={disabled}
              placeholder={placeholder}
              onKeyDown={(e) => {
                if (commandItems.length > 0) {
                  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                    e.preventDefault();
                    setCommandActive((a) => (a + (e.key === "ArrowDown" ? 1 : commandItems.length - 1)) % commandItems.length);
                    return;
                  }
                  if ((e.key === "Enter" || e.key === "Tab") && !e.shiftKey && !e.nativeEvent.isComposing) {
                    e.preventDefault();
                    commandItems[Math.min(commandActive, commandItems.length - 1)].choose();
                    return;
                  }
                  if (e.key === "Escape") {
                    e.preventDefault();
                    setCommandDismissed(true);
                    return;
                  }
                }
                if (suggestions.length > 0) {
                  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                    e.preventDefault();
                    setMentionActive((a) => (a + (e.key === "ArrowDown" ? 1 : suggestions.length - 1)) % suggestions.length);
                    return;
                  }
                  if ((e.key === "Enter" || e.key === "Tab") && !e.nativeEvent.isComposing) {
                    e.preventDefault();
                    pickMention(suggestions[Math.min(mentionActive, suggestions.length - 1)].name);
                    return;
                  }
                  if (e.key === "Escape") {
                    e.preventDefault();
                    setMention(null);
                    return;
                  }
                }
                // Only with a draft, so Tab still leaves an empty box for the next control.
                if (e.key === "Tab" && onCycle && text.trim() && !e.altKey && !e.ctrlKey && !e.metaKey) {
                  e.preventDefault();
                  onCycle(e.shiftKey);
                  return;
                }
                if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                  e.preventDefault();
                  submitComposer();
                }
              }}
            />
          </div>
          {compact ? (
            <div className="flex items-center gap-2" data-testid="composer-compact-row">
              <ComposerSheet
                open={sheet}
                onOpenChange={setSheet}
                options={options.filter((o) => controls[o.id] || o.id === "context" || o.id === "attach" || o.id === "code")}
                control={sheetControl}
                counts={{ context: chips.length, attach: files.items.length, code: snippets.items.length }}
              />
              <div className="flex min-w-0 flex-1 items-center justify-end gap-1">
                {options.filter((o) => o.id === "model").map(control)}
                {actions}
              </div>
              <SendButton label={send.label} disabled={send.disabled} title={send.title} tone={send.tone} />
            </div>
          ) : (
          /* One row at any width: everything that isn't used every message lives in +, and a mode that is on shows as its own pill. */
          <div className="flex min-w-0 items-center gap-2" data-testid="composer-controls">
            <ComposerMenu
              open={sheet}
              onOpenChange={setSheet}
              // "header" options join the menu only where the caller passes their control: the Welcome has no header.
              options={options.filter((o) => o.place !== "actions" && o.id !== "send-mode" && o.id !== "persona" && (controls[o.id] || o.id === "context" || o.id === "attach" || o.id === "code"))}
              control={sheetControl}
              counts={{ context: chips.length, attach: files.items.length, code: snippets.items.length }}
              disabled={disabled}
            />
            <div className="flex min-w-0 flex-1 items-center gap-1.5 overflow-hidden" data-testid="composer-modes">
              {/* Before the first message, who answers is the choice that matters most, so the persona stays in view. */}
              {options.filter((o) => o.id === "persona" || (o.opens === "toggle" && o.on)).map(control)}
            </div>
            <div className="flex flex-none items-center gap-1">
              {options.filter((o) => o.place === "actions" || o.id === "send-mode").map(control)}
              {actions}
              <SendButton label={send.label} disabled={send.disabled} title={send.title} tone={send.tone} />
            </div>
          </div>
          )}
        </div>
      </form>
      <ComposerHints>{hints}</ComposerHints>
    </>
  );
}
