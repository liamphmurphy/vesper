# ADR: Antigravity (`agy`) integration baseline

- **Status:** Accepted for agy 1.5.9+ (ACP stdio session transport + unified Vesper MCP subagents). Re-check on agy updates with `TestAgyProbe`.
- **Ticket:** [[LAZYAGENTS-190]], epic "Antigravity harness support". Adapter
  fixes: [[LAZYAGENTS-192]].
- **Evidence:**
  - Contract and findings: [antigravity.md](antigravity.md)
  - Captured `--version`, `--help`, `agy models` and the model's tool declarations:
    [antigravity-cli-1.5.8.txt](antigravity-cli-1.5.8.txt)
  - Recorded streams: `server/internal/harness/testdata/antigravity-{turn,error}.jsonl`
  - Probe: `TestAgyProbe` in `server/internal/harness/antigravity_probe_test.go`
- **Modelled on:** ADR-020 (OpenCode baseline) and the wiki pattern "Verify harness
  adapters against the real CLI safely".

## Context

PR #367 added Antigravity as a third harness, built from Google's docs because no
`agy` binary was at hand. Its contract marked most of the stream, tool names and
permission behaviour as unverified. This ADR records what the real CLI does,
and what Vesper decided because of it.

## How it was verified

agy 1.5.8 (linux arm64) was installed from Google's manifest with its SHA-512
checked, and run with `env -i`, a temp `HOME`, a fake `GEMINI_API_KEY` and every
proxy pointed at a dead port. **`GOOGLE_GEMINI_BASE_URL` pointed at a local stub of
the Gemini API**: agy speaks plain `streamGenerateContent` (SSE), so the stub could
script the model's replies, including tool calls, a 429 with `RetryInfo`, and
exact `usageMetadata`. Stubs for Vesper's MCP endpoint and tool-policy endpoint
recorded what the real hook and MCP client sent. The turn ran through Vesper's
real launcher (`agy-launch.py`), settings, `hooks.json` and `agy_policy.py`.

`TestAgyProbe` does all of this, needs no key, sends nothing off the machine, and
skips when `AGY_PROBE`/`AGY_BIN` aren't set.

## Decisions

1. **Headless invocation (bidirectional ACP stdio):**
   `python3 .lazyagents/agy-launch.py [--config <cfg>] agy acp --stdio --disable-telemetry`
   (`SessionInvocation` / `RunSession` in `server/internal/harness/antigravity_session.go`, with `LAZYAGENTS_AGY_ACP=1`).
   Legacy `-p <prompt> --output-format stream-json` remains on `Antigravity.Invocation` for non-session callers; never pass `--dangerously-skip-permissions`.
   Tagged subagent runs (`ConfigTag != ""`) set `isolated_home: true` so `agy_launch.py` creates a symlinked temporary `$HOME` sharing credentials/history while isolating `settings.json`, `mcp_config.json`, and `hooks.json`.
2. **ACP prompt completion & errors:** Turns end on the `session/prompt` JSON-RPC response, checking both RPC errors and `agent executor error:` text updates.
3. **Usage & context occupancy:** Context occupancy updates come from `session/update` (`usage_update` -> `used` -> `ContextTokens`), and turn usage is reported in the `session/prompt` result (`usage`).
4. **Tool names and in-process ACP permissions:** Built-in tools (`read_file`, `write_file`, `edit_file`, `run_command`, `search_web`) and `call_mcp_tool` are mapped by `antigravityTool` and `agy_policy.py`. Under `LAZYAGENTS_AGY_ACP=1`, `agy_policy.py` passes calls through (`allow`) so `agy acp` emits `session/request_permission` over stdio to `RunSession`, which evaluates `CheckTool` in-process and answers `allow_once` / `reject_once`. When `LAZYAGENTS_SUBAGENT_JOB_ID` is set, PreToolUse hooks also send `X-Vesper-Subagent-Job`. Native subagent files (`.agents/agents/*`) are removed; native `Agent`/`Task`/`invoke_subagent`/`swarm`/`run_workflow` calls are denied in favor of Vesper MCP `run_subagent`, and built-in `schedule` is denied because headless turns exit on idle. Read-only `explorer` subagents with `repo:read` omit the static `command(*)` deny so `agy_policy.py` and `CheckToolWithSpec`/`shellpolicy.go` allow read-only search commands (`rg`, `ls`, `grep`, `git grep`) while still blocking mutations and writes.
5. **Turn interrupt:** Cancellation/pause sends ACP `session/cancel` notification over stdio.
6. **Quota & credentials & skills & timeouts:** Google's 429 text (`RESOURCE_EXHAUSTED` + `retryDelay`) triggers fallback and limit reset calculation; native `agy acp --login` bundle (`harness:google`) and API-key `authenticate` fallback (only when `GEMINI_API_KEY` is present on `-32000`) are both supported. Skills live in `.agents/skills/` (git-excluded), instructions in `.agents/rules/vesper-01..06.md`, and `lazyagents` MCP sets `timeoutSeconds: 2400` (`antigravity.go`) to accommodate `run_subagent` calls.

## Capability table (agy 1.5.9+)

| Capability | Status | Evidence / note |
| --- | --- | --- |
| Tool gating (static) | **Verified** | `settings.permissions.deny` blocks `command(*)`/`write_file(*)` even when the hook approves |
| Tool gating (per call) | **Verified** | ACP `session/request_permission` (`LAZYAGENTS_AGY_ACP=1`) and `agy_policy.py` PreToolUse hook check every call (built-in, MCP, native subagent) via `CheckTool`; `reject_once`/`deny` reaches the model |
| Permission prompt (approve one action mid-turn) | **Verified (`PermissionPrompt = true`)** | ACP `session/request_permission` lets Vesper evaluate `CheckToolWithSpec` / request approval dynamically per call |
| Turn cancellation | **Verified** | ACP `session/cancel` over stdio interrupts an in-flight `session/prompt` |
| Live context occupancy | **Verified** | `session/update` (`usage_update.used`) updates `ContextTokens` |
| Subagents (`run_subagent` / `run_subagents`) | **Verified** | Unified via Vesper MCP `run_subagent` + batch `run_subagents` (works around `agy acp` sequential MCP calls), isolated `$HOME` + `OptionNoMCP` ACP worker (`TestSubagentCrossHarnessE2E`, `TestSubagentBatchConcurrencyLimit`, `TestAgyProbe/session_subagent_orchestration`, `TestAgyProbe/session_explorer_readonly_shell`) |
| Native cost | **Unsupported** | Tokens only; cost `unknown` |
| Token usage and cache | **Verified** | Reported on `session/prompt` result (`inputTokens + cachedReadTokens`, `outputTokens`, `cachedReadTokens`) |
| Resume | **Verified** | ACP `session/load` (with `t.SessionID`) and `-p --conversation ID` |
| Skills | **Verified (native)** | agy lists `.agents/skills/<name>/SKILL.md` to the model, as Codex reads it |
| Vesper MCP tools | **Verified** | Streamable HTTP with bearer header and `timeoutSeconds: 2400`; called via `call_mcp_tool` |
| Image generation | **Not available with an API key (observed)** | `generate_image` is in agy's internal list but was never declared to the model; needs a real key to settle (LAZYAGENTS-196) |
| Model listing | **Via Gemini API only** | `agy models` needs a sign-in |
| Usage/quota probe | **Unsupported** | Nothing to read with a key |

## Consequences

- Before this ADR, every Vesper tool a chat called on Antigravity reached the
  policy as `call_mcp_tool`, an unknown tool needing `tests:run`. Read-only chats
  were refused their own tools, failed tool calls vanished from the run log,
  quota failures didn't fall back, resumed turns counted earlier turns'
  tokens again, and ticket runs never saw their skills. Each is fixed with a test.
- With no network, agy retries forever. Only the run's `max_runtime` ends such a
  turn, and Docker egress must allow the Gemini endpoint.
- A real-model run (with a key) is still needed for: image generation, the
  model's actual tool use, and real quota wording. Track it on LAZYAGENTS-198.
