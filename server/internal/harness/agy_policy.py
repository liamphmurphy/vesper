"""Run-scoped policy bridge for Antigravity (agy) PreToolUse hooks. Fail closed.

agy writes {"toolCall": {"name", "args"}, ...} to stdin and expects a JSON
{"decision", "reason"} on stdout. The call is renamed to the tool names Vesper's
policy (runs.CheckTool) already knows from Claude Code, so one rule set holds
every harness. Vesper allows -> "auto_approve" (agy's own prompt is then
skipped); anything else, or any failure, is "deny".
"""
import json
import os
import re
import sys
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
    if name in ("invoke_subagent", "define_subagent", "manage_subagents", "swarm", "send_message"):
        out = {"description": FIRST(args, "Role", "Name", "TypeName", "action")}
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


def main():
    try:
        event = json.load(sys.stdin)
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
