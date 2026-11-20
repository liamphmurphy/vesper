# ADR: Antigravity (`agy`) integration baseline

- **Status:** Accepted for agy 1.5.8 once this PR merges. Re-check on agy updates
  with the probe (below).
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

1. **Headless invocation:**
   `agy -p <prompt> --output-format stream-json [--model] [--effort] [--conversation]`.
   Resume with `--conversation` works under `-p`. Never pass
   `--dangerously-skip-permissions`.
2. **The stream is read from the `result` line, not the exit code**, because a
   failed turn can exit 0. A tool step ends in `DONE` **or `ERROR`**, and both are
   tool results.
3. **Usage is summed from the `agent_response` steps of the turn's own process.**
   `result.usage` is cumulative over a resumed conversation. agy's `input_tokens`
   excludes cache reads, and its `output_tokens` already include thinking.
4. **Tool names follow what agy declares to the model:** `read_file`,
   `write_file`, `edit_file`, `run_command`, `search_web`. All MCP tools go through
   `call_mcp_tool`, which Vesper names `mcp__<server>__<tool>` for its policy.
   agy's subagent tools (`invoke_subagent`, `swarm`…) are mapped to `Agent`, which
   Vesper's policy allows only for the run's declared sub agent types, as for
   Claude Code (`explorer` and `helper`, see ADR-explorer.md). The policy keeps
   one rule set for all three harnesses.
5. **Quota:** Google's 429 text ("exceeded your current quota", `RESOURCE_EXHAUSTED`)
   is a usage limit, so fallbacks apply, and `retryDelay` is the reset time.
6. **Credentials:** native Antigravity login (`agy acp --login` -> `harness:google`
   delivered as container files in `$HOME`, or host CLI login in local mode).
   Model discovery uses `agy models` natively rather than AI Studio's API.
7. **Skills** are written to `.agents/skills/` (git-excluded), which agy
   discovers natively. Before this, they went to `.lazyagents/skills/`, listed in
   chat AGENTS.md only, so ticket runs never learned about them.
8. **Usage/quota display:** none to read. A key has no plan allowance, and `/usage`
   is TUI-only, so the orb shows "Usage unknown" and cost is `unknown`.

## Capability table (agy 1.5.8)

| Capability | Status | Evidence / note |
| --- | --- | --- |
| Tool gating (static) | **Verified** | `settings.permissions.deny` blocks `command(*)`/`write_file(*)` even when the hook approves |
| Tool gating (per call) | **Verified** | PreToolUse hook gets every call (built-in, MCP, subagent) with full args; `deny` reaches the model with its reason |
| Permission prompt (approve one action mid-turn) | **Unsupported** | A deny rule can't be lifted inside a turn; `PermissionPrompt` stays false |
| Native cost | **Unsupported** | Tokens only; cost `unknown` |
| Token usage and cache | **Verified** | Per request on `agent_response` steps; semantics above |
| Resume | **Verified** | `--conversation ID` with `-p`, same id, history replayed |
| Skills | **Verified (native)** | agy lists `.agents/skills/<name>/SKILL.md` to the model, as Codex reads it; Vesper now writes them there |
| Vesper MCP tools | **Verified** | Streamable HTTP with bearer header; called via `call_mcp_tool` |
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
