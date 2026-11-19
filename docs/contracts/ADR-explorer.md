# ADR: The explorer sub agent on every harness

- **Status:** Accepted for Claude Code 2.1.325 and agy 1.5.9; Codex 0.169.0
  deliberately left without one (below).
- **Ticket:** [[LAZYAGENTS-258]], epic "Reduce agent turn latency and startup
  overhead".
- **Evidence:**
  - Probe: `TestAgyProbe/explorer` in
    `server/internal/harness/antigravity_probe_test.go` (real agy, stub Gemini
    API, as in [ADR-antigravity.md](ADR-antigravity.md)).
  - agy's own docs, shipped in the binary's builtin skills
    (`migrate-agent-settings`, `agy-customizations`), and `agy changelog`.
  - `codex-cli 0.169.0`'s config keys (`agents`, `default_subagent_model`,
    `max_depth`, `features.multi_agent`), read from the binary.
- **Modelled on:** the wiki pattern "Verify harness adapters against the real CLI
  safely".

## Context

A lead ticket run on Claude Code gets one read-only sub agent, `explorer`
(`agentdef.ExplorerOn`): broad searches and multi-file reads run on a cheap
model and come back as a short answer with `file:line` references, so the
lead's context stays small and it spends fewer serial model turns exploring.
The LAZYAGENTS-251 profile showed what agy did without one: twelve consecutive
one-lookup turns, about 288 s, before its first edit.

## Decision

The explorer is the same contract everywhere it exists: one agent type,
`explorer`, with `agentdef.ExplorerDescription` and `agentdef.ExplorerPrompt`,
read-only tools, a cheaper model than the lead's, for lead ticket runs only,
off with `explorer: "false"`. `runs.CheckTool` allows `Agent` with
`subagent_type: explorer` when `ExplorerOn` holds and denies every other sub
agent, whichever harness asked.

**Claude Code** (unchanged): `--agents .lazyagents/claude-agents.json`, tools
`Read`, `Grep`, `Glob`, model `OptionExplorerModel` (default Haiku).

**Antigravity:** a custom agent at `.agents/agents/explorer.md`, git-excluded:

```markdown
---
name: explorer
description: "<ExplorerDescription>"
subagent: true
mainAgent: false
inheritMcp: false
model: flash
tools: [read_file]
---

# Explorer

<ExplorerPrompt>
```

Verified against agy 1.5.9:
- the lead's prompt lists `explorer` with its description among its subagents;
- the lead's `invoke_subagent {TypeName: "explorer"}` reaches Vesper's policy
  hook as `Agent` with `subagent_type: explorer`;
- the explorer's requests go to `gemini-3.8-flash` while the lead's go to its
  own model;
- the explorer is declared `read_file` and agy's messaging and task tools, and
  none of `run_command`, `write_file`, `edit_file`, `invoke_subagent` or the
  lead's MCP tools (`inheritMcp: false`). Without `inheritMcp: false` it gets
  every MCP server the lead has.

`model: flash` is agy's fast tier; agy doesn't take Claude model names, so
`OptionExplorerModel` doesn't apply to it. The `grep_search`, `find_by_name` and
`list_dir` tools agy's changelog says custom agents may list weren't declared
to the explorer in 1.5.9; `read_file` is what it searches with.

**Codex:** no explorer. Codex 0.169 has sub agents (`features.multi_agent` and
`[agents.<role>]` with a description and config file), but Vesper turns
`features.multi_agent` off on purpose: delegation goes through Vesper's
run-scoped delegate service, which tracks, budgets and reviews it. Turning it on
for an explorer would give the model Codex's own spawn tools for any role.
Holding that to one read-only role means checking those tools' names and
arguments through the PreToolUse hook against a stub Responses API, as was done
for agy. That wasn't done here, so the Codex adapter is unchanged.

## Consequences

- An agy lead gets the explorer by default, as a Claude Code lead does. Its
  effect is measured by get_run's efficiency summary (LAZYAGENTS-257):
  `single_call_turns` and `ms_to_first_edit` before and after.
- Re-run `TestAgyProbe/explorer` on agy updates: the frontmatter keys are agy's
  and could change.
- Codex: revisit with a Codex probe if Codex runs show the same serial
  exploration.
