"use client";

import Link from "next/link";
import { useId, useState } from "react";
import { useBootstrap, useCreateArtifact, useCreateTicket, useCreateWikiPage } from "@/lib/api/hooks";
import { defaultSavePath, withChatBacklink } from "@/lib/chat-context";
import { wikiHref } from "@/lib/wikilinks";
import { Button } from "@/components/ui/button";
import { Field, TextInput } from "@/components/ui/primitives";
import { DialogShell } from "@/components/domain/artifact-dialogs";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

type Props = { chat: { id: string; title: string; project?: string }; body: string };

function SaveDialog({
  title,
  label,
  fieldLabel,
  initial,
  pending,
  error,
  done,
  onSave,
  onClose,
  open,
}: {
  title: string;
  label: string;
  fieldLabel: string;
  initial: string;
  pending: boolean;
  error: unknown;
  done?: { href: string; text: string };
  onSave: (value: string) => void;
  onClose: () => void;
  open: boolean;
}) {
  const [value, setValue] = useState(initial);
  const id = useId();
  return (
    <DialogShell
      open={open}
      onOpenChange={(o) => !o && onClose()}
      title={title}
      footer={
        done ? (
          <>
            <Link href={done.href} className="mr-auto text-13 text-accent hover:underline">{done.text}</Link>
            <Button variant="outline" onClick={onClose}>Done</Button>
          </>
        ) : (
          <>
            <Button variant="outline" onClick={onClose}>Cancel</Button>
            <Button variant="primary" disabled={pending || !value.trim()} onClick={() => onSave(value.trim())}>
              {pending ? "Saving…" : label}
            </Button>
          </>
        )
      }
    >
      {!done && (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            if (!pending && value.trim()) onSave(value.trim());
          }}
        >
          <Field label={fieldLabel} htmlFor={id}>
            <TextInput id={id} autoFocus value={value} onChange={(e) => setValue(e.target.value)} />
          </Field>
        </form>
      )}
      {done && <p role="status" className="text-13">Saved.</p>}
      {error != null && !done && (
        <p role="alert" className="text-13 text-pill-blocked-fg">{errorText(error)}</p>
      )}
    </DialogShell>
  );
}

/** Save an assistant reply as a wiki page, report artifact, or ticket, with a link back to the chat. */
export type SaveMode = "wiki" | "artifact" | "ticket";

function defaultTicketTitle(body: string, fallback: string): string {
  const first = body
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((l) => l.replace(/^#+\s*/, "").replace(/^[-*]\s+/, "").trim())
    .find((l) => l.length > 0 && !l.startsWith("```"));
  const candidate = first || fallback || "Follow-up from chat";
  return candidate.length > 80 ? `${candidate.slice(0, 79).trimEnd()}…` : candidate;
}

function PromoteTicketDialog({
  chat,
  body,
  onClose,
}: Props & { onClose: () => void }) {
  const bootstrap = useBootstrap();
  const projects = bootstrap.data?.projects ?? [];
  const create = useCreateTicket();
  const [title, setTitle] = useState(() => defaultTicketTitle(body, chat.title));
  const [projectKey, setProjectKey] = useState(() => chat.project || projects[0]?.key || "");
  const [description, setDescription] = useState(() => withChatBacklink(body, chat.id, chat.title));
  const titleId = useId();
  const projId = useId();
  const descId = useId();
  const resolvedProject = projectKey || projects[0]?.key || "";
  const created = create.data;

  const submit = () => {
    if (create.isPending || !title.trim() || !resolvedProject) return;
    create.mutate({
      project_key: resolvedProject,
      title: title.trim(),
      description_md: description.trim() || undefined,
    });
  };

  return (
    <DialogShell
      open
      onOpenChange={(o) => !o && onClose()}
      title="Promote to ticket"
      footer={
        created ? (
          <>
            <Link href={`/tickets/${created.key}`} className="mr-auto text-13 text-accent hover:underline">
              Open {created.key}
            </Link>
            <Button variant="outline" onClick={onClose}>Done</Button>
          </>
        ) : (
          <>
            <Button variant="outline" onClick={onClose}>Cancel</Button>
            <Button variant="primary" disabled={create.isPending || !title.trim() || !resolvedProject} onClick={submit}>
              {create.isPending ? "Creating…" : "Create ticket"}
            </Button>
          </>
        )
      }
    >
      {!created ? (
        <form
          className="flex flex-col gap-3"
          onSubmit={(e) => {
            e.preventDefault();
            submit();
          }}
        >
          {projects.length > 1 && (
            <Field label="Project" htmlFor={projId}>
              <select
                id={projId}
                value={resolvedProject}
                onChange={(e) => setProjectKey(e.target.value)}
                className="h-9 w-full rounded-md border border-border-strong bg-surface px-2.5 text-13 text-fg outline-none focus:border-accent"
              >
                {projects.map((p) => (
                  <option key={p.key} value={p.key}>{p.name} ({p.key})</option>
                ))}
              </select>
            </Field>
          )}
          <Field label="Title" htmlFor={titleId}>
            <TextInput id={titleId} autoFocus value={title} onChange={(e) => setTitle(e.target.value)} />
          </Field>
          <Field label="Description" htmlFor={descId}>
            <textarea
              id={descId}
              rows={5}
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              className="w-full resize-y rounded-md border border-border-strong bg-surface p-2 text-13 text-fg outline-none focus:border-accent"
            />
          </Field>
        </form>
      ) : (
        <p role="status" className="text-13">Created {created.key}.</p>
      )}
      {create.error != null && !created && (
        <p role="alert" className="text-13 text-pill-blocked-fg">{errorText(create.error)}</p>
      )}
    </DialogShell>
  );
}

/**
 * Saving a reply to the wiki, as an artifact, or promoting it to a ticket: the dialog for the mode
 * the person picked (from the message's ⋯ menu), and where it went once saved.
 */
export function SaveDialogs({ chat, body, mode, onClose }: Props & { mode: SaveMode | null; onClose: () => void }) {
  const page = useCreateWikiPage();
  const artifact = useCreateArtifact();
  const md = withChatBacklink(body, chat.id, chat.title);
  const close = () => {
    onClose();
    page.reset();
    artifact.reset();
  };
  const savedPage = page.data;
  const savedArtifact = artifact.data;

  return (
    <>
      {mode === "wiki" && (
        <SaveDialog
          open
          title="Save to wiki"
          label="Save page"
          fieldLabel="Page path"
          initial={defaultSavePath(chat.title)}
          pending={page.isPending}
          error={page.error}
          done={savedPage && { href: wikiHref(savedPage.path ?? ""), text: `Open ${savedPage.path ?? "page"}` }}
          onSave={(path) => page.mutate({ path, body_md: md, project_key: chat.project })}
          onClose={close}
        />
      )}
      {mode === "artifact" && (
        <SaveDialog
          open
          title="Save as artifact"
          label="Save report"
          fieldLabel="Title"
          initial={chat.title}
          pending={artifact.isPending}
          error={artifact.error}
          done={savedArtifact && { href: `/artifacts/${savedArtifact.id}`, text: `Open ${savedArtifact.title}` }}
          onSave={(title) => {
            const f = new FormData();
            if (chat.project) f.set("project_key", chat.project);
            f.set("type", "report");
            f.set("title", title);
            f.set("body_md", md);
            artifact.mutate(f);
          }}
          onClose={close}
        />
      )}
      {mode === "ticket" && <PromoteTicketDialog chat={chat} body={body} onClose={close} />}
    </>
  );
}
