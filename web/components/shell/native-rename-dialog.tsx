"use client";

import { Dialog } from "radix-ui";
import { useState, type FormEvent } from "react";
import { Button } from "@/components/ui/button";
import { TextInput } from "@/components/ui/primitives";

/**
 * A rename box for the Mac app, where a sidebar row or the title's menu has no inline field: a
 * dialog with one text field. `request` is what is being renamed (null while closed); `onSubmit`
 * gets the trimmed, non-empty new name. Closing without saving, or saving the same name, changes nothing.
 */
export function NativeRenameDialog({ request, onClose, onSubmit }: {
  request: { heading: string; label: string; value: string; maxLength?: number } | null;
  onClose: () => void;
  onSubmit: (name: string) => void;
}) {
  return (
    <Dialog.Root open={!!request} onOpenChange={(o) => { if (!o) onClose(); }}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content aria-describedby={undefined} className="motion-dialog fixed left-1/2 top-[16vh] z-50 w-[min(420px,calc(100%-32px))] -translate-x-1/2 rounded-2xl border border-border-float bg-surface-raised p-5 shadow-[var(--shadow-float)] outline-none">
          {request && <RenameForm key={request.heading + request.value} request={request} onClose={onClose} onSubmit={onSubmit} />}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function RenameForm({ request, onClose, onSubmit }: { request: { heading: string; label: string; value: string; maxLength?: number }; onClose: () => void; onSubmit: (name: string) => void }) {
  const [name, setName] = useState(request.value);
  const save = (e: FormEvent) => {
    e.preventDefault();
    const n = name.trim();
    if (n && n !== request.value) onSubmit(n);
    onClose();
  };
  return (
    <form onSubmit={save} className="flex flex-col gap-3">
      <Dialog.Title className="text-16 font-semibold text-fg">{request.heading}</Dialog.Title>
      <TextInput aria-label={request.label} value={name} maxLength={request.maxLength} autoFocus onFocus={(e) => e.currentTarget.select()} onChange={(e) => setName(e.target.value)} />
      <div className="flex justify-end gap-2">
        <Dialog.Close asChild><Button variant="secondary" type="button">Cancel</Button></Dialog.Close>
        <Button variant="primary" type="submit">Save</Button>
      </div>
    </form>
  );
}
