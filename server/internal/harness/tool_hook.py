"""Run-scoped policy bridge shared by Claude Code and Codex. Fail closed."""
import json
import os
import sys
import urllib.request

def main():
    try:
        event = {"tool_name": "mcp__lazyagents__whoami", "tool_input": {}} if sys.argv[1:] == ["--check"] else json.load(sys.stdin)
        headers = {"Content-Type": "application/json", "Authorization": "Bearer " + os.environ["LAZYAGENTS_POLICY_TOKEN"]}
        job_id = os.environ.get("LAZYAGENTS_SUBAGENT_JOB_ID", "")
        if job_id:
            headers["X-Vesper-Subagent-Job"] = job_id
        request = urllib.request.Request(
            os.environ["LAZYAGENTS_POLICY_URL"],
            data=json.dumps({"tool": event["tool_name"], "input": event.get("tool_input", {})}).encode(),
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
            print("{}")
            return
        reason = decision.get("reason", "Vesper denied the tool")
    except Exception:
        reason = "Vesper tool policy is unavailable. Do not run this tool; end the turn and ask for help."
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))

if __name__ == "__main__":
    main()
