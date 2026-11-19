import { ButtonLink } from "@/components/ui/button";
import { Card } from "@/components/ui/primitives";

/**
 * Export everything to move Vesper to another machine. It's a plain download
 * link: the server streams the archive, so a large instance never sits in
 * the browser's memory. Import stays a command because it needs an empty
 * instance with the same SECRETS_KEY, which only the operator can arrange.
 */
export function BackupSection() {
  return (
    <Card bodyClassName="flex flex-col gap-4 p-[18px]">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="max-w-[520px] text-13 text-fg-secondary">
          One zip with every table and every stored file: tickets, chats, wiki, artifacts, library, secrets (still encrypted) and settings.
          Large instances take a while to prepare, and the download starts straight away.
        </p>
        <ButtonLink href="/api/v1/instance/export" variant="outline" icon="download" prefetch={false}>
          Export everything
        </ButtonLink>
      </div>
      <ul className="flex list-disc flex-col gap-1.5 pl-5 text-13 text-fg-tertiary">
        <li>The archive holds all your data. Keep it like a database backup.</li>
        <li>
          Sign-in sessions, runner registrations and live playgrounds stay behind: you sign in again on the new machine.
        </li>
        <li>
          To load it, set the same <code className="font-mono">SECRETS_KEY</code> on a fresh instance and run{" "}
          <code className="font-mono">docker compose run --rm -T api import - &lt; vesper-export.zip</code> before starting the API.
          See “Move Vesper to another machine” in the guide.
        </li>
      </ul>
    </Card>
  );
}
