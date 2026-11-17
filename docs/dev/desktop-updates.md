# Desktop: how Vesper.app updates (LAZYAGENTS-249)

Status: **proposed; needs Liam's approval.** The implementation in this PR is
the low-risk part of the recommended option, off by default, so approving a
different option only means changing or removing it.

## The constraint

`make desktop-dmg` builds an ad-hoc signed, not notarised app
(`docs/dev/microvm-architecture.md`, "Signed, notarised distribution" is out of
scope). That rules out Electron's built-in updater:

- **Squirrel.Mac** (`autoUpdater`) verifies that the new bundle's code
  signature matches the running one's designated requirement. Ad-hoc
  signatures have no stable identity, so every update fails verification.
- Even with matching signatures, a quarantined download from the internet is
  blocked by Gatekeeper unless notarised.

## Options

| Option | What it takes | Pros | Cons |
| --- | --- | --- | --- |
| A. Notify + manual replace (recommended) | Check a release feed; notify; open the download page. Person drags the new app into Applications. | No signing infrastructure. Nothing runs code it downloaded. Works with ad-hoc builds. | A few clicks per update; `xattr -cr` once for a downloaded DMG. |
| B. Developer ID + notarisation + Squirrel.Mac | Apple Developer account ($99/yr), signing identity in CI, notarisation step, update server (or GitHub releases via electron-updater). | Real one-click auto-update; no Gatekeeper prompts. | Cost and setup; secrets in CI; the `vesper` binary's virtualization entitlement must be signed with `--options runtime` and re-tested. |
| C. Self-replacing unsigned updater | App downloads a DMG, verifies a checksum, swaps its own bundle with a helper script. | Automatic without Apple. | Runs downloaded code with no signature trust; easy to brick the app mid-swap; strips the guarantees Gatekeeper gives. Not recommended. |

## Recommendation: A now, B when distribution widens

Vesper is single-user and built locally today, so A covers it. If the app is
ever distributed beyond Liam's machines, do B.

## What this PR implements (option A)

- **Settings › Updates › Check for new versions daily** (off by default: it's
  a network call to `api.github.com`). The feed URL is a setting
  (`updates.feedUrl`), https only. "Vesper › Check for Updates…" checks on
  demand.
- `desktop/src/updates.ts` reads the GitHub "latest release" JSON, ignores
  drafts and pre-releases, compares semver, and accepts a download page only
  on `github.com` or the feed's own host, over https. A newer version is
  announced once with a notification that opens the page.
- **Data survives upgrades**: `userData` (`~/Library/Application Support/Vesper`)
  is outside the bundle; replacing `Vesper.app` doesn't touch it, and
  `vesper app` applies new migrations on the next start.
- **Downgrade guard**: the app records the version that last opened the data
  (`app-state.json`). When an older build opens it, Vesper warns before
  starting the stack (the database may have migrations it doesn't know) and
  offers Quit, which changes nothing. The newer version number is kept, so the
  warning repeats until the newer app is back.
- **A failed update leaves a working app**: there's no in-place swap, so the
  old app keeps working until the person replaces it.

## Not done

- No release feed exists yet: GitHub releases for `liamphmurphy/vesper` would
  need a DMG attached per version (a CI job, or `make desktop-dmg` + `gh
  release create`). Until then a check finds nothing.
- Option B is unbuilt.
