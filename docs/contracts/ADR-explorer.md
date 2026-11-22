# ADR: The explorer sub agent on every harness

- **Status:** Superseded by the Unified Vesper MCP subagents addendum below (previously native `claude --agents` / agy `.agents/agents/*`; now unified across Claude Code, Codex, and Antigravity via `run_subagent`).
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

## Addendum: sub agents for every persona run

- **Status:** Accepted for Claude Code 2.1.325 and agy 1.5.9.
- **Evidence:** `TestClaudeProbe/helper` (real claude, stub Messages API) and
  `TestAgyProbe/helper` (real agy, stub Gemini API), both in
  `server/internal/harness`.

The explorer is no longer lead-only, and it has a sibling. Every run with tools
on Claude Code or agy, chats and delegated runs included, gets
`agentdef.SubagentTypes`: `explorer` and `helper`. `helper` takes a
self-contained task on the lead's own model with the file, shell and web tools
the run allows (`claudeHelperTools`, `agyHelperAgent`) and none of Vesper's MCP
tools, so plans, steps and `complete_run` stay the lead's. A read-only run's
helper only reads. `subagents: "false"` turns both off; `explorer: "false"`
drops only the explorer. Asides and `no_tools` turns get neither.
`runs.CheckTool` allows exactly the declared types.

Verified on both harnesses:
- the policy hook sees the sub agent's own tool calls (the helper's `Bash`), so
  scopes, approvals and read-only chats hold inside it; Claude Code sends them
  with `agent_id` and `agent_type`;
- the helper runs on the lead's model and gets only its declared tools.

**Claude Code runs sub agents in the background by default** in 2.1.325: the
`Agent` call returns "Async agent launched", the lead ends its turn, and it is
woken again when the sub agent finishes, so the stream carries one `result`
per wake, each with only its segment's usage (the explorer had this too).
Vesper sets `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` whenever sub agents are
on; the lead then waits for the report within its turn and the stream has one
result. `TestClaudeProbe/helper` fails without it.

Known gap: Claude Code's `result.usage` counts only the lead's tokens;
`total_cost_usd` includes the sub agents'. Token counts on a run with sub
agents therefore read low while its cost is right.

Codex is still left out, for the reason above: `features.multi_agent` would
hand the model Codex's own spawn tools for any role, and nobody has checked
their names, arguments and the children's tool calls through the hook.

## Addendum: Unified Vesper MCP subagents (`run_subagent`)

- **Status:** Accepted across Claude Code, Codex, and Antigravity.
- **Evidence:** `TestToolPolicySubagents`, `TestToolPolicySubagentJobHeader`, `TestRunSubagentToolLifecycleAndValidation`, `TestSubagentCrossHarnessE2E`, `TestSubagentConcurrencyLimit`, `TestSubagentCanceledWhenParentInterrupted`, and `TestIsolatedSubagentSessionConfigs`.

Native harness subagent configurations (`claude --agents`, `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, and agy `.agents/agents/{explorer,helper}.md`) have been removed. Instead, subagents share one Vesper-owned orchestration path across all three harnesses:

1. **Unified MCP tool (`run_subagent`):** Available across Claude Code, Codex, and Antigravity whenever `agentdef.SubagentsOn(spec)` is true (all runs with tools except `OptionSubagents="false"`, `OptionNoTools="true"`, `OptionNoMCP="true"`, or `OptionAside="true"`). Native `Agent` / `Task` tool calls are denied by `runs.CheckTool`, directing the model to `run_subagent`.
2. **In-turn `subagent_jobs` queue and worker pool (`runner/subagents.go`):** `run_subagent` creates a row in `subagent_jobs` (ephemeral, excluded from instance export in `transfer/schema.go`) and waits for terminal state. During an active parent turn with `SubagentsOn`, `runner.startSubagentWorker` polls and runs up to the workspace's `workspaces.max_concurrent_subagents` limit (default `3`, configurable `1–16` via Settings / `PUT /runner/settings`) in parallel in the parent workspace over each harness's bidirectional `SessionHarness` interface.
3. **Isolated per-job specs & configs (`runs.SubagentSpec`):** Every subagent runs with `OptionNoMCP="true"`, `OptionSubagents="false"`, `LAZYAGENTS_SUBAGENT_JOB_ID=<job_id>`, and a unique `ConfigTag="subagent-"+job.ID.String()` (isolated `mcp.json`/`claude-settings.json`, `<tag>-tool-policy.py`, and `<tag>-agy-config.json` + `<tag>-agy-policy.py` + symlink-isolated `$HOME` in `agy_launch.py`). `explorer` runs read-only (`readonly="true"`, `sandbox="read-only"`, fast per-harness model: `DefaultExplorerModel`, `gpt-5-mini`, `gemini-3.8-flash`, or `OptionExplorerModel`); on Antigravity, read-only `explorer` subagents with `repo:read` omit the static `command(*)` deny so `shellpolicy.go` gates `run_command` to read-only search commands (`rg`, `ls`, `grep`, `git grep`). `helper` inherits the parent's model and workspace scopes clamped to the parent. `Turn.SystemAppend` delivers the role prompt plus an explicit subagent scope boundary without modifying `AGENTS.md`.
4. **Policy & usage accounting:** In-process `CheckToolWithSpec(c, subSpec, in)` evaluates stdio permission callbacks, and `tool_hook.py` / `agy_policy.py` forward `X-Vesper-Subagent-Job` to `POST /api/v1/agent/tool-policy` for PreToolUse command hooks (failing closed unless the job is `running` on the caller's run). Subagent `tool_call`/`tool_result` events are emitted on the parent run with `subagent: true`, and tokens/cost/tool calls are recorded on `subagent_jobs` and rolled up onto the parent `runs` row via `AddRunUsage`. Canceling or pausing the parent turn interrupts/kills active subagents and cancels queued/running jobs.
