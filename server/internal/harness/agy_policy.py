"""Run-scoped policy and Stop hook bridge for Antigravity (agy).

For PreToolUse (fail closed): agy writes {"toolCall": {"name", "args"}, ...} to
stdin and expects JSON {"decision", "reason"} on stdout. The call is renamed to
the tool names Vesper's policy (runs.CheckTool) already knows from Claude Code,
so one rule set holds every harness.

For Stop (registered in ACP mode): when the model yields with NO_TOOL_CALL while
non-daemon background tasks are still running (fullyIdle is false), block until
an undelivered completion message appears in the conversation's brain directory
(or the wait slice expires) and return {"decision": "continue"} so agy acp does
not resolve session/prompt early and kill the background command.
"""
import json
import os
import re
import sys
import time
import urllib.request

# Keep in sync with antigravityTool in antigravity.go (a test runs both).
FIRST = lambda a, *keys: next((a[k] for k in keys if isinstance(a.get(k), str) and a[k]), "")
PATH = ("AbsolutePath", "TargetFile", "file_path", "path", "Path", "DirectoryPath", "SearchPath")


def canonical(name, args):
    if not isinstance(args, dict):
        args = {}
    if name == "run_command":
        out = {"command": FIRST(args, "CommandLine", "command", "cmd")}
        desc = FIRST(args, "toolSummary", "description")
        if desc:
            out["description"] = desc
        return "Bash", out
    if name in ("read_file", "view_file", "view_file_outline"):
        return "Read", {"file_path": FIRST(args, *PATH)}
    if name in ("write_file", "write_to_file", "create_file"):
        return "Write", {"file_path": FIRST(args, *PATH)}
    if name == "call_mcp_tool":
        server, tool = FIRST(args, "ServerName"), FIRST(args, "ToolName")
        if not server or not tool:
            return name, args
        tool_input = args.get("Arguments")
        return "mcp__" + server + "__" + tool, tool_input if isinstance(tool_input, dict) else None
    if name in ("invoke_subagent", "define_subagent", "manage_subagents", "swarm", "send_message", "run_workflow"):
        out = {"description": FIRST(args, "Role", "Name", "TypeName", "action", "Description")}
        if name == "invoke_subagent" and isinstance(args.get("TypeName"), str) and args["TypeName"]:
            out["subagent_type"] = args["TypeName"]
        return "Agent", out
    if name in ("replace_file_content", "multi_replace_file_content", "edit_file"):
        return "Edit", {"file_path": FIRST(args, *PATH)}
    if name == "list_dir":
        return "LS", {"path": FIRST(args, *PATH)}
    if name == "grep_search":
        return "Grep", {"pattern": FIRST(args, "Query", "query", "pattern"), "path": FIRST(args, *PATH)}
    if name == "find_by_name":
        return "Glob", {"pattern": FIRST(args, "Pattern", "pattern"), "path": FIRST(args, *PATH)}
    if name == "search_web":
        return "WebSearch", {"query": FIRST(args, "query", "Query")}
    if name == "read_url_content":
        return "WebFetch", {"url": FIRST(args, "Url", "url", "URL")}
    m = re.match(r"^mcp[_./:-]+(.+)$", name)
    if m:
        return "mcp__" + m.group(1), args
    return name, args


def list_undelivered(undelivered_dir):
    try:
        return set(os.listdir(undelivered_dir))
    except OSError:
        return set()


def handle_stop(event):
    try:
        if event.get("fullyIdle", True) or event.get("terminationReason") != "NO_TOOL_CALL":
            print(json.dumps({"decision": "allow"}))
            return
        max_wait = float(os.environ.get("LAZYAGENTS_AGY_STOP_WAIT_SECONDS", "240"))
        if max_wait < 0:
            max_wait = 0.0
        artifact_dir = event.get("artifactDirectoryPath") or ""
        undelivered_dir = os.path.join(artifact_dir, ".system_generated", "messages", "undelivered") if artifact_dir else ""
        exec_num = event.get("executionNum") or 0
        initial = list_undelivered(undelivered_dir) if undelivered_dir else set()

        # If a completion notification already landed before this Stop hook
        # started on the initial yield, continue immediately so agy delivers it.
        if initial and exec_num == 0:
            print(json.dumps({
                "decision": "continue",
                "reason": "A background task finished. Review its output and continue your turn.",
            }))
            return

        # Wait for a new completion notification in undelivered/ (bounded below
        # the hook's timeout) so long commands don't burn LLM turns polling.
        wait_budget = min(max_wait, 2.0) if (not undelivered_dir or initial) else max_wait
        deadline = time.monotonic() + wait_budget
        completed = False
        while time.monotonic() < deadline:
            current = list_undelivered(undelivered_dir) if undelivered_dir else set()
            if current - initial:
                completed = True
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(0.2, remaining))

        if completed:
            reason = "A background task finished. Review its output and continue your turn."
        else:
            reason = "Background tasks are still running. Check their status or wait for them to finish before ending your turn."
        print(json.dumps({"decision": "continue", "reason": reason}))
    except Exception:
        print(json.dumps({"decision": "allow"}))


def main():
    try:
        event = json.load(sys.stdin)
        if isinstance(event, dict) and event.get("hookEventName") == "Stop":
            handle_stop(event)
            return
        call = event["toolCall"]
        args = call.get("args")
        tool, tool_input = canonical(call["name"], args)
        headers = {"Content-Type": "application/json", "Authorization": "Bearer " + os.environ["LAZYAGENTS_POLICY_TOKEN"]}
        job_id = os.environ.get("LAZYAGENTS_SUBAGENT_JOB_ID", "")
        if job_id:
            headers["X-Vesper-Subagent-Job"] = job_id
        request = urllib.request.Request(
            os.environ["LAZYAGENTS_POLICY_URL"],
            data=json.dumps({"tool": tool, "input": tool_input}).encode(),
            headers=headers,
            method="POST",
        )

        # Credentials must never follow a redirect to another origin.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None

        with urllib.request.build_opener(NoRedirect).open(request, timeout=15) as response:
            decision = json.load(response)
        if decision.get("decision") == "allow":
            # In ACP mode return "allow" (not "auto_approve") so agy still emits
            # session/request_permission and RunSession's CheckTool runs as a
            # second gate while this hook continues to block denied writes early.
            hook_decision = "allow" if os.environ.get("LAZYAGENTS_AGY_ACP") == "1" else "auto_approve"
            print(json.dumps({"decision": hook_decision}))
            return
        reason = decision.get("reason", "Vesper denied the tool")
    except Exception:
        reason = "Vesper tool policy is unavailable. Do not run this tool; end the turn and ask for help."
    print(json.dumps({"decision": "deny", "reason": reason}))


if __name__ == "__main__":
    main()
