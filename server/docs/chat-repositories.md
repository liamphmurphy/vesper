# Repositories in persona chats

A persona's **Write code** capability enables repository work. Its saved
repository list no longer authorizes or revokes access: GitHub credentials
remain the authority on which repositories can be read or pushed.

Settings → **Repositories & GitHub owners** manages a shared discovery
catalogue for the signed-in person. It offers the account connected through
the GitHub token and its visible organizations as one-click presets. Choosing
a preset saves all repositories under that owner; discovery alone saves
nothing. Organizations are collected from authenticated memberships and
organization owners in accessible repositories, including with fine-grained
tokens. Partial discovery leaves the account and manual entry available.

Expand **Enter a repository or owner manually** for other owners, individual
repositories, and GitHub URLs. Save a repository as `owner/name` or a GitHub
URL. To include every repository owned by an account or organization,
choose **All repos under a username or organization** and enter the name,
such as `liamphmurphy`. This includes every repository visible to the
credential under that owner, including private personal repositories.
The API also accepts `owner/*` and `https://github.com/owner/*` as shortcuts. Public user listings are combined with the authenticated
repository listing so private repositories are not silently omitted. Only
the complete owner wildcard is supported, not partial names such as
`owner/app*`. Owner lists are paginated and
cached for five minutes, scoped to the person and credential. Refresh clears
that delay. Only repositories visible to the credential are discovered.

The chat's repository picker and `/repo owner/name` select a repository in the
same conversation. A saved short name works when it identifies exactly one
repository; ambiguous names require a qualified choice. Full GitHub URLs and
`owner/name` work without a saved source. Selections made during a reply apply
to the next turn.

Coding personas have `search_repositories` and `use_repository`. The latter
attaches a checkout and returns a shell-quoted `setup_command`. The persona
must run it from the workspace root before using the returned directory. This
supports attaching another repository during a turn, including a chat that
started without a repository. Setup and git failures must be reported rather
than treated as a successful checkout.

Existing chats keep their original checkout at `.`. Additional repositories
live under `.lazyagents/repos/owner/name`. Branch ownership, changes, and
checkpoint snapshots belong to each attachment. Cleanup checkpoints every
checkout before removing a workspace; a new segment saves earlier local
workspaces before it clones and restores snapshots. If a checkpoint push
fails, Vesper retains the workspace. Checkpoint branches are automatically
deleted once a successful pull request contains all of their changes. Switching
repositories leaves the other checkouts and conversation messages intact.

Automatic test services are selected from the active repository at the start
of a turn. When working across repositories in one turn, the persona must run
each repository's commands in its own directory and start additional test
services explicitly with the sandboxed Docker API. `start_playground` accepts
an optional attached `repository`; its setup, process directories, and OpenAPI
path are relative to that checkout, and its default services come from that
repository. Saved playground specs can be reused at different checkout paths.

Migration `00101_chat_repositories.sql` copies persona repository lists into
personal discovery sources and existing chat repository/branch records into
attachments without moving files. The legacy persona `repos` API field and
first-repository default remain compatible with existing clients; new source
management lives in the shared catalogue. Removing a discovery source neither
detaches a checkout nor disables coding. Turn off **Write code** to revoke the
persona's coding capability.

The source API keeps the existing `organization` kind for account and
organization wildcards, so existing saved sources need no database migration.
Both `repository` inputs ending in `/*` and explicit owner-source inputs are
normalized to the same saved owner.
