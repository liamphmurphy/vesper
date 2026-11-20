"""Install this turn's agy configuration, then run agy. Fail closed.

agy reads its permission rules, MCP servers and hooks from files under $HOME,
so a turn container (fresh, one per turn) gets them written here from
.lazyagents/agy-config.json just before agy starts. The MCP bearer token is
substituted from the environment so it is never written into the workspace.
Outside a container (the fake backend's stand-in) nothing is installed: that
would write into a real person's home.
"""
import json
import os
import shutil
import sys
import tempfile


def write(path, data):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def load(path):
    try:
        with open(path) as f:
            value = json.load(f)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def install(cfg):
    home = os.path.expanduser("~")
    token = os.environ.get(cfg["token_env"], "")
    # Settings: ours win; the permission lists are replaced, never merged, so a
    # stale allow rule can't outlive the policy this turn was given.
    settings_path = os.path.join(home, ".gemini", "antigravity-cli", "settings.json")
    settings = load(settings_path)
    settings.pop("modelProvider", None)
    settings.update(cfg["settings"])
    write(settings_path, settings)
    servers = json.loads(json.dumps(cfg["mcp_servers"]).replace("{{token}}", token))
    write(os.path.join(home, ".gemini", "config", "mcp_config.json"), {"mcpServers": servers})
    hooks_path = os.path.join(home, ".gemini", "config", "hooks.json")
    hooks = load(hooks_path)
    hooks["vesper-policy"] = {"enabled": True, "PreToolUse": [{"matcher": "*", "hooks": [{"command": cfg["hook_command"], "timeout": 20}]}]}
    write(hooks_path, hooks)


def main():
    args = sys.argv[1:]
    cfg_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "agy-config.json")
    if len(args) >= 2 and args[0] == "--config":
        cfg_arg, args = args[1], args[2:]
        cfg_path = cfg_arg if os.path.isabs(cfg_arg) or os.path.exists(cfg_arg) else os.path.join(os.path.dirname(os.path.abspath(__file__)), os.path.basename(cfg_arg))
    if not args:
        raise RuntimeError("agy_launch.py: missing program argument")
    program, args = args[0], args[1:]
    with open(cfg_path) as f:
        cfg = json.load(f)
    if cfg.get("install"):
        install(cfg)
    # execvp's own error for a missing program names no file, which reads as a
    # problem with the configuration above.
    if shutil.which(program) is None:
        raise RuntimeError(program + " isn't installed in the agent image; rebuild agent-base")
    os.execvp(program, [program, *args])


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        message = "Vesper Antigravity setup: " + str(error)
        print(json.dumps({"event": "result", "result": {"status": "ERROR", "error": message}}), flush=True)
        print(message, file=sys.stderr)
        sys.exit(1)
