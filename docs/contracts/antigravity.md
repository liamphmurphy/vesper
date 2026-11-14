# Antigravity (`agy`) contract

What Vesper's Antigravity harness (`server/internal/harness/antigravity.go`)
relies on in Google's Antigravity CLI, and the evidence for each part. The
decision record is [ADR-antigravity.md](ADR-antigravity.md).

> **Status: verified against agy 1.5.8** (linux arm64, 2026-11-13). The probe ran
> the real binary headless through Vesper's own launcher, settings and policy
> hook. A local stub stood in for the Gemini API (`GOOGLE_GEMINI_BASE_URL`), so
> the stub chose the model's replies and token counts, and **agy produced
> everything else.** Captured help, models output and tool declarations:
> [antigravity-cli-1.5.8.txt](antigravity-cli-1.5.8.txt). Recorded streams:
> `server/internal/harness/testdata/antigravity-*.jsonl`.
>
> Re-run it after an agy update. It needs no key and reaches nothing outside
> the machine:
>
> ```
> cd server && AGY_PROBE=1 AGY_BIN=$(command -v agy) go test ./internal/harness -run AgyProbe -v
> ```
>
> Add `AGY_RECORD=internal/harness/testdata` to refresh the fixtures.
>
> **Not verified:** what a real Gemini model does, because the stub plays the
> model. That covers which tools it picks, image generation, and real quota
> wording beyond the 429 body Google documents.

## Credentials: native `agy acp --login` bundle

Vesper signs Antigravity in natively via `agy acp --login` (inside a throwaway
sign-in container, or using the host's `agy` login in local/no-key mode).

- The saved login bundle is stored encrypted as `harness:google`
  (`chatmodels.KeySecret`) containing the auth/config files captured from `$HOME`
  after `agy acp --login` (`chatmodels.ParseAntigravityAuth`, with non-UTF-8
  files base64-encoded in `files_b64`), never passed in environment variables
  (`runner.AntigravityAuthEnv` unpacks into `$HOME` in Docker containers).
- `agy_launch.py` strips any stale `modelProvider` key so `agy` runs with its
  native Antigravity provider rather than AI Studio.
- Only `kind: "subscription"` is accepted (`httpapi.checkHarnessCredential`),
  and models are listed directly via `agy models` (`chatmodels.ParseAgyModels`).

## Invocation

```
python3 .lazyagents/agy-launch.py agy -p "<prompt>" --output-format stream-json \
  [--model M] [--effort E] [--conversation ID]
```

All of these flags are in `agy --help` (1.5.8). `--effort` takes
low|medium|high|xhigh|max. `--dangerously-skip-permissions` is **never passed**,
because it would defeat the hook and the deny rules. `--sandbox` isn't used: the
container is the boundary.

**Resume (verified):** `--conversation ID` with `-p` continues the conversation
under the same id. The model receives the earlier turns, and `num_turns` counts up.

**Exit code:** 0 for a successful turn. 3 when the turn fails with no response
(an HTTP error such as a 404 or a 429 with a `RetryInfo`). **A turn can also
report `status: ERROR` and exit 0**: one 429 retried into a partial answer did.
Read the `result` line, not the exit code.

## Event stream (verified)

NDJSON on stdout, one object per line, each with `event`:

- `init`: `conversation_id` sits **beside** `init`, not in it. `init` carries
  `cwd`, `tools` (agy's internal tool names, not the model's) and `permission_mode`.
  Becomes a `harness_started` lifecycle event carrying the session id.
- `step_update`: `conversation_id`, `step_index`, `state`, `step_type`.
  - `state` is `ACTIVE` while a step runs, then **`DONE` or `ERROR`**. A denied
    or failed tool ends in `ERROR` with `tool_info.error.{type,message}`, e.g.
    `TOOL_ERROR` / `tool call denied by pre-tool hook: <reason>`.
  - `user_input`: the prompt.
  - `agent_response`: the model's text in `text_delta`, possibly over several
    updates. On `DONE` it carries **`usage` for that one model request**.
  - `tool`: `tool_name` plus `tool_info.{name, parameters, output, error}`.
    Parameters arrive at `ACTIVE` and again at the end. `output` is a short
    summary for built-in tools (`read_file` → "1 lines, 25 bytes") and the
    text for MCP tools.
  - `subagent`: `tool_name: invoke_subagent` with
    `subagent_info.subagents[].{type_name, role, initial_prompt}`, and no tool_info.
  - `error_message`: a failed model call, with no text. The `result` line carries
    the error.
- `result`: `{conversation_id, status: SUCCESS|ERROR, response, error,
  duration_seconds, num_turns, usage, finished_reason}`. Exactly one per run.
- stderr: on failure, `error: …` and
  `AGY_ERROR: {"short_error", "status", "error_code", "code_kind", "retryable", "error_id"}`.
  The runner keeps stderr in the raw log; the parser reads such a line if it sees one.

### Usage

Both usages carry `{input_tokens, output_tokens, thinking_tokens, cache_read_tokens,
total_tokens}`. With known Gemini `usageMetadata` (prompt 1200, cached 1000,
candidates 30, thoughts 7), agy reported `input_tokens` 200, `cache_read_tokens`
1000, `output_tokens` 37 and `thinking_tokens` 7. So:

- `input_tokens` **excludes** cache reads. Vesper's input is
  `input_tokens + cache_read_tokens`, of which `cache_read_tokens` were cached.
- `output_tokens` **already includes** thinking. Adding `thinking_tokens` would
  count it twice.
- `result.usage` is **cumulative over a resumed conversation**. The parser
  therefore sums the per-step usage of its own process and ignores
  `result.usage`. A turn that fails before any request reports no usage.

Cost is `unknown`: agy reports tokens, and Vesper keeps no Gemini price list.

### Failures and limits

A 429 with Google's quota body ends as `status: ERROR` with the full message, for example
`Error 429, Message: You exceeded your current quota, …, Status: RESOURCE_EXHAUSTED,
Details: [map[@type:…RetryInfo retryDelay:41s]]`. `harness.UsageLimit` matches
"exceeded your current quota" and "resource_exhausted", which triggers the fallbacks.
`harness.LimitReset` reads `retryDelay` as the reset time. With no `RetryInfo`, agy
retried once after about 4s before giving up.

**With no network at all, agy never ends the turn.** It retries the model call,
printing an `error_message` step each time, until it is killed. The probe stopped
it at 2 minutes after 7 retries. The run's `max_runtime` is what bounds such a turn.

## Tool names (verified)

What the model is offered, and so what the hook and the stream report (full
declarations in the captured file):

| agy tool | Arguments | Vesper name |
| --- | --- | --- |
| `read_file` | `Path` (absolute), `StartLine`, `EndLine` | `Read` |
| `write_file` | `Path`, `Content`, `Overwrite`, `Append` | `Write` |
| `edit_file` | `Path`, `Target`, `Replacement` | `Edit` |
| `run_command` | `CommandLine`, `toolSummary`, `WaitMsBeforeAsync` | `Bash` |
| `search_web` | `query`, `domain` | `WebSearch` |
| `call_mcp_tool` | `ServerName`, `ToolName`, `Arguments` | `mcp__<server>__<tool>` |
| `invoke_subagent`, `define_subagent`, `manage_subagents`, `swarm`, `send_message` | | `Agent` (denied by policy) |
| `manage_task`, `schedule`, `ask_question`, `list_resources`, `read_resource` | | unchanged: unknown, so `tests:run` |

**Every MCP tool goes through `call_mcp_tool`.** There are no per-tool
`mcp_<server>_<tool>` names. `antigravityTool` (Go) and `canonical`
(`agy_policy.py`) must agree; `TestAgyPolicyHookAgreesWithTheParser` runs both.
`init`'s list also holds internal names (`view_file`, `write_to_file`,
`list_dir`, `grep_search`…), which are still mapped in case a step reports one.

## Permissions: two layers, fail closed (verified)

`agy` has no read-only mode. The launcher writes
`~/.gemini/antigravity-cli/settings.json`, `~/.gemini/config/mcp_config.json` and
`~/.gemini/config/hooks.json` in the turn container, and agy 1.5.8 loads all three
headless:

1. **Deny rules from the spec** (`agyDenyRules`): `command(*)` unless the run may
   test or write, `write_file(*)` unless it may write, `read_url(*)`/`execute_url(*)`
   without web access, and everything for a no-tools turn. **Verified:** they hold
   **even when the hook answers `auto_approve`**. A read-only chat's `run_command`
   and `write_file` were refused with "Matches user-configured deny rule" although
   the policy allowed them.
2. **The PreToolUse hook** (`agy_policy.py` → `runs.CheckTool`). **Verified:** it
   receives `{"toolCall": {"name", "args"}}`, with the full args, for every tool
   including `call_mcp_tool` and `invoke_subagent`. A `deny` reaches the model as
   `tool call denied by pre-tool hook: <reason>`.

Unchanged consequence: **a scope set to `requires_approval` is denied for the
whole turn**, because the deny rule is written before the turn. So
`Capabilities[antigravity].PermissionPrompt` stays false.

`trustedWorkspaces` with the workspace path: no trust prompt stalled a headless run.

## Skills (verified)

agy lists every `.agents/skills/<name>/SKILL.md` in the workspace to the model,
with its frontmatter description, the same location Codex reads. Vesper writes a
run's skills there (`SkillFilesFor`) and git-excludes them. The chat's AGENTS.md
doesn't index them for Antigravity, as for Claude Code.

## MCP (verified)

`mcp_config.json` `{"mcpServers": {name: {"serverUrl", "headers", "timeoutSeconds"}}}`.
agy connects over Streamable HTTP with the bearer header the launcher substitutes
(`server/discover`, `initialize` at protocol 2025-11-25, `tools/list`, then
`tools/call` on use). It lists the server's tools to the model by name in the
system prompt. The `mcp(<server>/*)` allow rule is still written; whether agy
needs it with `toolPermission: request-review` wasn't isolated.

## Images

**Not available with an API key in 1.5.8 (observed):** `generate_image` is in
`init`'s internal list but was **not** declared to the model in any probe run.
No setting enabling it turned up. The collection path (`collectAntigravityScript`:
image paths named in a tool's output, under `$HOME/.gemini`) is therefore exercised
only by the fake. Image generation on Antigravity (LAZYAGENTS-196) needs a real key
to settle.

## Network

Turn containers need the Gemini endpoint (`generativelanguage.googleapis.com`).
agy also posts telemetry to `play.googleapis.com` and self-updates in the
background; both failed harmlessly behind the dead proxy.

## Install

`curl -fsSL https://antigravity.google/cli/install.sh | bash`. The script reads a
platform manifest from Google's auto-updater, downloads a tarball from
`storage.googleapis.com/antigravity-public/…`, checks its SHA-512 against the
manifest, then runs `agy install` (shell setup). The agent image downloads the
pinned release tarball directly and verifies its SHA-512 checksum at build time
(`deploy/agent-base/Dockerfile`, `AGY_RELEASE` / `INSTALL_ANTIGRAVITY`).
