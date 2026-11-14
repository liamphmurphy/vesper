"""Run-scoped policy bridge shared by Claude Code and Codex. Fail closed."""
import json
import os
import sys
import urllib.error
import urllib.request

def main():
    try:
        event = {"tool_name": "mcp__lazyagents__whoami", "tool_input": {}} if sys.argv[1:] == ["--check"] else json.load(sys.stdin)
        request = urllib.request.Request(
            os.environ["LAZYAGENTS_POLICY_URL"],
            data=json.dumps({"tool": event["tool_name"], "input": event.get("tool_input", {})}).encode(),
            headers={"Content-Type": "application/json", "Authorization": "Bearer " + os.environ["LAZYAGENTS_POLICY_TOKEN"]},
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
    except urllib.error.HTTPError as error:
        if error.code == 401:
            reason = "Vesper control API rejected this turn's credential (HTTP 401). Check runner control routing and turn credentials before retrying."
        elif error.code >= 500:
            reason = f"Vesper tool policy backend is unavailable (HTTP {error.code}). Retry after the service recovers."
        else:
            reason = f"Vesper tool policy request was rejected (HTTP {error.code}). Check the control API configuration before retrying."
    except (urllib.error.URLError, TimeoutError):
        reason = "Vesper control API is unreachable. Check runner networking before retrying."
    except Exception:
        reason = "Vesper tool policy could not be checked. Check the policy hook configuration and response before retrying."
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))

if __name__ == "__main__":
    main()
