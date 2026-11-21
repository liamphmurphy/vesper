"use client";

import { useRouter } from "next/navigation";
import { Dialog } from "radix-ui";
import { useState, type FormEvent } from "react";
import { ApiError } from "@/lib/api/client";
import { useForkChat } from "@/lib/api/hooks";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { TextInput } from "@/components/ui/primitives";

export interface ForkTarget {
  messageId: string;
  gitBranch?: string;
  gitCommitSha?: string;
}

/** Modal that branches an earlier point of a conversation into a new independent chat. */
export function ForkDialog({
  chatId,
  defaultTitle,
  hasRepo,
  target,
  onClose,
}: {
  chatId: string;
  defaultTitle: string;
  hasRepo: boolean;
  target: ForkTarget | null;
  onClose: () => void;
}) {
  const router = useRouter();
  const fork = useForkChat(chatId);
  const [title, setTitle] = useState("");
  const [branchRepo, setBranchRepo] = useState(false);
  const [branchName, setBranchName] = useState("");

  function openChange(open: boolean) {
    if (!open) onClose();
  }

  function submit(e: FormEvent) {
    e.preventDefault();
    if (!target || fork.isPending) return;
    fork.mutate(
      {
        message_id: target.messageId,
        ...(title.trim() ? { title: title.trim() } : {}),
        ...(hasRepo ? { branch_repo: branchRepo, ...(branchRepo && branchName.trim() ? { branch_name: branchName.trim() } : {}) } : {}),
      },
      {
        onSuccess: (created) => {
          onClose();
          router.push(`/chat/${created.id}`);
        },
      },
    );
  }

  const refLabel = target?.gitCommitSha
    ? `${target.gitBranch ? `${target.gitBranch} @ ` : ""}${target.gitCommitSha.slice(0, 7)}`
    : target?.gitBranch;

  const errText = fork.error instanceof ApiError
    ? fork.error.message
    : fork.error instanceof Error
      ? fork.error.message
      : "Couldn’t fork conversation. Try again.";

  return (
    <Dialog.Root
      open={!!target}
      onOpenChange={(open) => {
        if (open && target) {
          setTitle(defaultTitle ? `Fork of ${defaultTitle}` : "Forked chat");
          setBranchRepo(hasRepo && !!(target.gitCommitSha || target.gitBranch));
          setBranchName("");
          fork.reset();
        }
        openChange(open);
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby={undefined}
          onOpenAutoFocus={() => {
            if (target) {
              setTitle(defaultTitle ? `Fork of ${defaultTitle}` : "Forked chat");
              setBranchRepo(hasRepo && !!(target.gitCommitSha || target.gitBranch));
              setBranchName("");
              fork.reset();
            }
          }}
          className="motion-dialog fixed left-1/2 top-[16vh] z-50 w-[min(440px,calc(100%-32px))] -translate-x-1/2 rounded-2xl border border-border-float bg-surface-raised p-5 shadow-[var(--shadow-float)] outline-none"
        >
          <form onSubmit={submit} className="flex flex-col gap-3.5">
            <div className="flex items-center gap-2">
              <Icon name="branch" size={16} className="text-fg-secondary" />
              <Dialog.Title className="text-16 font-semibold text-fg">Fork conversation from here</Dialog.Title>
            </div>
            <p className="text-12 text-fg-secondary">
              Starts a new independent chat seeded with every message up to this point.
            </p>
            <label className="flex flex-col gap-1">
              <span className="text-12 font-medium text-fg-secondary">Title</span>
              <TextInput
                aria-label="Forked chat title"
                value={title}
                placeholder={defaultTitle ? `Fork of ${defaultTitle}` : "Forked chat"}
                autoFocus
                onChange={(e) => setTitle(e.target.value)}
              />
            </label>
            {hasRepo && (
              <div className="flex flex-col gap-2 rounded-lg border border-border-subtle bg-surface p-3">
                <label className="flex cursor-pointer items-start gap-2.5">
                  <input
                    type="checkbox"
                    checked={branchRepo}
                    onChange={(e) => setBranchRepo(e.target.checked)}
                    className="mt-0.5 size-4 rounded border-border accent-accent"
                  />
                  <span className="min-w-0 flex-1 text-13 text-fg">
                    Branch repository from this turn
                    <span className="mt-0.5 block text-12 text-fg-tertiary">
                      {refLabel
                        ? `Starts on a new branch at ${refLabel}.`
                        : "Starts on a new fork branch from the default branch."}
                    </span>
                  </span>
                </label>
                {branchRepo && (
                  <label className="flex flex-col gap-1 pl-6">
                    <span className="text-12 text-fg-tertiary">Branch name (optional)</span>
                    <TextInput
                      aria-label="Fork branch name"
                      value={branchName}
                      placeholder="feat/fork-…"
                      onChange={(e) => setBranchName(e.target.value)}
                    />
                  </label>
                )}
              </div>
            )}
            {fork.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{errText}</p>}
            <div className="flex justify-end gap-2 pt-1">
              <Dialog.Close asChild>
                <Button variant="secondary" type="button" disabled={fork.isPending}>Cancel</Button>
              </Dialog.Close>
              <Button variant="primary" type="submit" disabled={fork.isPending}>
                {fork.isPending ? "Forking…" : "Fork chat"}
              </Button>
            </div>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
