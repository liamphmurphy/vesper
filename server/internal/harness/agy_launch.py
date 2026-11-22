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


def link_except(src_dir, dst_dir, excluded):
    os.makedirs(dst_dir, mode=0o700, exist_ok=True)
    if not os.path.isdir(src_dir):
        return
    for entry in os.listdir(src_dir):
        if entry in excluded:
            continue
        src = os.path.join(src_dir, entry)
        dst = os.path.join(dst_dir, entry)
        if not os.path.exists(dst) and not os.path.islink(dst):
            os.symlink(src, dst)


def isolate_home(real_home):
    iso_home = tempfile.mkdtemp(prefix="vesper-agy-home-")
    os.chmod(iso_home, 0o700)
    link_except(real_home, iso_home, {".gemini"})
    link_except(os.path.join(real_home, ".gemini"), os.path.join(iso_home, ".gemini"), {"antigravity-cli", "config"})
    link_except(
        os.path.join(real_home, ".gemini", "antigravity-cli"),
        os.path.join(iso_home, ".gemini", "antigravity-cli"),
        {"settings.json"},
    )
    link_except(
        os.path.join(real_home, ".gemini", "config"),
        os.path.join(iso_home, ".gemini", "config"),
        {"mcp_config.json", "hooks.json"},
    )
    return iso_home


def install(cfg, home, base_home):
    token = os.environ.get(cfg["token_env"], "")
    # Settings: ours win; the permission lists are replaced, never merged, so a
    # stale allow rule can't outlive the policy this turn was given.
    settings_path = os.path.join(home, ".gemini", "antigravity-cli", "settings.json")
    base_settings_path = os.path.join(base_home, ".gemini", "antigravity-cli", "settings.json")
    settings = load(base_settings_path)
    settings.pop("modelProvider", None)
    settings.update(cfg["settings"])
    write(settings_path, settings)
    servers = json.loads(json.dumps(cfg["mcp_servers"]).replace("{{token}}", token))
    write(os.path.join(home, ".gemini", "config", "mcp_config.json"), {"mcpServers": servers})
    hooks_path = os.path.join(home, ".gemini", "config", "hooks.json")
    base_hooks_path = os.path.join(base_home, ".gemini", "config", "hooks.json")
    hooks = load(base_hooks_path)
    policy_hook = {
        "enabled": True,
        "PreToolUse": [{"matcher": "*", "hooks": [{"command": cfg["hook_command"], "timeout": 20}]}],
    }
    # In ACP mode, agy resolves session/prompt with end_turn as soon as the model
    # yields even when a background run_command is still running; the Stop hook
    # holds the turn open until background tasks finish and wake the model up.
    if os.environ.get("LAZYAGENTS_AGY_ACP") == "1":
        policy_hook["Stop"] = [{"command": cfg["hook_command"], "timeout": 300}]
    hooks["vesper-policy"] = policy_hook
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
        real_home = os.path.expanduser("~")
        target_home = isolate_home(real_home) if cfg.get("isolated_home") else real_home
        install(cfg, target_home, real_home)
        if cfg.get("isolated_home"):
            os.environ["HOME"] = target_home
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
