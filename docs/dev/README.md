# Developer notes

Background for people and agents working on Vesper itself. None of this is
needed to run it; start with the [README](../../README.md) and the
[guide](../guide.md) for that.

- [plan.md](plan.md): the original architecture and build plan. Code comments
  cite its sections (for example `docs/dev/plan.md §6.5`). The repository
  layout and phase notes describe the project as it was planned, before the
  rename from LazyAgents.
- [microvm-architecture.md](microvm-architecture.md): architecture, security
  gates, single-DMG packaging, and bare-metal macOS build-out plan for the
  `microvm` runner backend.
- [test-environments.md](test-environments.md) and [playgrounds.md](playgrounds.md):
  ADRs for per-turn test environments and live playground previews.
- [safari-extension.md](safari-extension.md): Vesper for Safari, the extension bundled
  in Vesper.app that shares tabs with personas, asks about pages and clips them.
- [handoff-log.md](handoff-log.md): the running handoff log agents kept while
  building phases 0–8. It's a historical record, not current instructions.
- [verification/](verification/): evidence and requirement matrices for
  individual tickets, linked from the guide.

The visual design references live in [../design-system/](../design-system/).
