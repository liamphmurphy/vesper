"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card, Field, TextArea } from "@/components/ui/primitives";
import { toast } from "@/components/ui/toast";
import { cx } from "@/lib/cx";
import { useImportHttpCollection } from "@/lib/api/http-client-hooks";

export type ImportTab = "bru" | "curl" | "openapi";

export function ImportDialog({
  workspaceId,
  folder,
  initialTab = "bru",
  onClose,
}: {
  workspaceId: string;
  /** Where the imported requests go; omitted for the workspace root. */
  folder?: { id: string; name: string } | null;
  initialTab?: ImportTab;
  onClose: () => void;
}) {
  const [tab, setTab] = useState<ImportTab>(initialTab);
  const [content, setContent] = useState("");
  const [bruFiles, setBruFiles] = useState<{ path: string; content: string }[]>([]);
  const [zipBase64, setZipBase64] = useState("");
  const [fileSummary, setFileSummary] = useState("");
  const importer = useImportHttpCollection(workspaceId);

  const handleFilePick = async (fileList: FileList | null) => {
    if (!fileList || fileList.length === 0) return;
    if (fileList.length === 1 && fileList[0].name.toLowerCase().endsWith(".zip")) {
      const buf = await fileList[0].arrayBuffer();
      const bytes = new Uint8Array(buf);
      let bin = "";
      for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
      setZipBase64(btoa(bin));
      setBruFiles([]);
      setFileSummary(`Selected archive: ${fileList[0].name}`);
      return;
    }
    const collected: { path: string; content: string }[] = [];
    for (const f of Array.from(fileList)) {
      if (!f.name.toLowerCase().endsWith(".bru")) continue;
      const rel = (f as File & { webkitRelativePath?: string }).webkitRelativePath || f.name;
      collected.push({ path: rel, content: await f.text() });
    }
    setBruFiles(collected);
    setZipBase64("");
    setFileSummary(`Loaded ${collected.length} .bru file${collected.length === 1 ? "" : "s"}`);
  };

  const submit = async () => {
    try {
      const res = await importer.mutateAsync({
        format: tab,
        content: content.trim() || undefined,
        folder_id: folder?.id ?? null,
        zip_base64: zipBase64 || undefined,
        files: bruFiles.length > 0 ? bruFiles : undefined,
      });
      toast({
        title: `Imported ${res.requests_created} request(s), ${res.folders_created} folder(s), ${res.environments_created} env(s)`,
        tone: "success",
      });
      onClose();
    } catch (e) {
      toast({ title: e instanceof Error ? e.message : "Import failed", tone: "error" });
    }
  };

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Import HTTP collection"
      className="fixed inset-0 z-50 grid place-items-center bg-black/60 p-4"
    >
      <Card
        title={folder ? `Import into “${folder.name}”` : "Import into Workspace"}
        className="w-full max-w-[600px]"
        action={
          <Button variant="ghost" icon="x" aria-label="Close" onClick={onClose} />
        }
      >
        <div className="flex flex-col gap-4">
          <div className="flex gap-1 border-b border-border-subtle pb-2">
            {(
              [
                ["bru", "Bruno (.bru / .zip)"],
                ["curl", "cURL"],
                ["openapi", "OpenAPI 3"],
              ] as const
            ).map(([id, label]) => (
              <button
                key={id}
                type="button"
                onClick={() => setTab(id)}
                className={cx(
                  "rounded-md px-3 py-1.5 text-12 font-medium",
                  tab === id ? "bg-selected text-fg" : "text-fg-secondary hover:bg-hover",
                )}
              >
                {label}
              </button>
            ))}
          </div>

          {tab === "bru" && (
            <div className="flex flex-col gap-3">
              <Field
                label="Upload .bru files or a Bruno collection .zip"
                hint="Supports folders, requests, auth blocks, and environments/*.bru"
              >
                <input
                  type="file"
                  multiple
                  accept=".bru,.zip"
                  onChange={(e) => handleFilePick(e.target.files)}
                  className="text-12 text-fg-secondary file:mr-3 file:rounded-md file:border file:border-border-strong file:bg-surface file:px-3 file:py-1.5 file:text-12 file:text-fg"
                />
              </Field>
              {fileSummary && <p className="text-12 text-state-done">{fileSummary}</p>}
              <Field label="Or paste a single .bru request">
                <TextArea
                  mono
                  rows={8}
                  value={content}
                  placeholder={"meta {\n  name: Get Users\n}\nget {\n  url: {{base_url}}/v1/users\n}"}
                  onChange={(e) => setContent(e.target.value)}
                />
              </Field>
            </div>
          )}

          {tab === "curl" && (
            <Field
              label="Paste a cURL command"
              hint="Works with a browser’s “Copy as cURL”. Becomes one request."
            >
              <TextArea
                mono
                autoFocus
                rows={7}
                value={content}
                placeholder={`curl -X POST "https://api.example.com/v1/items" -H "Authorization: Bearer tok" -d '{"name":"test"}'`}
                onChange={(e) => setContent(e.target.value)}
              />
            </Field>
          )}

          {tab === "openapi" && (
            <Field label="Paste OpenAPI 3 JSON or YAML">
              <TextArea
                mono
                rows={10}
                value={content}
                placeholder={"openapi: 3.0.3\nservers:\n  - url: https://api.example.com\npaths:\n  /v1/health:\n    get:\n      summary: Health"}
                onChange={(e) => setContent(e.target.value)}
              />
            </Field>
          )}

          <div className="flex justify-end gap-2">
            <Button variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button variant="primary" disabled={importer.isPending} onClick={submit}>
              {importer.isPending ? "Importing…" : "Import"}
            </Button>
          </div>
        </div>
      </Card>
    </div>
  );
}
