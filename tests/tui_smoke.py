"""Real application workflows through Vertex's PTY, parser, grid and input encoder.

Use --test-driver with the Zig test host for local checks without a build.
All homes, repositories, sockets, configuration and model traffic are isolated.
"""
import argparse
import contextlib
import getpass
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

from agent_mock import MARKER, model_server
from multiplexer_smoke import Host
from tui_report import report

FIXTURES = Path(__file__).resolve().with_name("tui-fixtures")
FRAMEWORKS = {
    "curses": ["python3", str(FIXTURES / "curses_fixture.py")],
    "ink": ["node", str(FIXTURES / "ink.mjs")],
    "textual": [str(FIXTURES / ".venv/bin/python"), str(FIXTURES / "textual_fixture.py")],
    "bubbletea": ["vertex-bubbletea-fixture"],
}


def run(*command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, timeout=30, **kwargs)


def environment(root, args):
    # This dictionary belongs only to fixture child processes, never os.environ.
    result = {key: value for key, value in os.environ.items() if key in (
        "PATH", "LD_LIBRARY_PATH", "TERMINFO", "TERMINFO_DIRS", "HELIX_RUNTIME")}
    result.update(HOME=str(root), XDG_CONFIG_HOME=str(root / "config"),
                  XDG_CACHE_HOME=str(root / "cache"), XDG_DATA_HOME=str(root / "data"),
                  XDG_STATE_HOME=str(root / "state"), XDG_RUNTIME_DIR=str(root / "runtime"),
                  SHELL="/bin/sh", LANG="C.UTF-8", LC_ALL="C.UTF-8", PS1="VERTEX_PROMPT> ",
                  NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
    result.update(USER=getpass.getuser(), LOGNAME=getpass.getuser(), PWD=str(root))
    result["NVIM_LOG_FILE"] = str(root / "nvim.log")
    if args.tools_dir:
        result["PATH"] = str(args.tools_dir.resolve()) + os.pathsep + result["PATH"]
        runtime = list(args.tools_dir.glob("hx-distribution/*/runtime"))
        if runtime:
            result["HELIX_RUNTIME"] = str(runtime[0].resolve())
    if args.test_driver:
        result["VERTEX_HOST_TEST_DRIVER"] = "1"
    for name in ("config", "cache", "data", "state", "runtime"):
        (root / name).mkdir(mode=0o700, exist_ok=True)
    run("git", "init", "-q", str(root))
    run("git", "-C", str(root), "config", "user.email", "vertex@example.invalid")
    run("git", "-C", str(root), "config", "user.name", "Vertex fixture")
    run("git", "-C", str(root), "config", "commit.gpgsign", "false")
    run("git", "-C", str(root), "config", "core.hooksPath", "/dev/null")
    return result


def key(host, code, **modifiers):
    host.send(key={"code": code, "text": chr(code) if 32 <= code < 127 else "", "modifiers": modifiers})


def shell_ready(host):
    host.send(input="printf '\\nVERTEX_RETURN_OK\\n'\r")
    state = host.wait(lambda s: any("VERTEX_RETURN_OK" in line and "printf" not in line for line in s["lines"]), "return to working shell")
    if not getattr(host, "in_tmux", False):
        assert not state["alternate"], state
        assert state["modes"]["kitty"] == 0 and state["modes"]["mouse_tracking"] == 0, state


def at_prompt(state):
    return state["lines"][state["cursor"]["row"]][:state["cursor"]["column"]].rstrip().endswith("VERTEX_PROMPT>")


def editor(host, app, root, command):
    path = root / "fixture.txt"
    path.write_text("VERTEX_BASE\nsecond row\n")
    options = []
    if app == "lazyvim":
        options = ["-c", "lua vim.diagnostic.set(vim.api.nvim_create_namespace('vertex_fixture'),0,{{lnum=0,col=0,end_col=6,severity=vim.diagnostic.severity.ERROR,message='VERTEX_DIAGNOSTIC'}},{virtual_text=true})"]
    host.send(input=shlex.join([*command, str(path), *options]) + "\r")
    host.wait(lambda s: s["alternate"] and "VERTEX_BASE" in "\n".join(s["lines"]), f"{app} startup")
    host.send(resize=[30, 100])
    host.wait(lambda s: s["rows"] == 30 and "VERTEX_BASE" in "\n".join(s["lines"]), f"{app} resized redraw")
    if app in ("nvim", "vim", "emacs"):
        key(host, ord("z"), control=True)
        host.wait(at_prompt, f"{app} suspend to shell")
        host.send(input="fg\r")
        host.wait(lambda s: "VERTEX_BASE" in "\n".join(s["lines"]), f"{app} resume redraw")
    if app == "lazyvim":
        host.wait(lambda s: any(cell["underline"] and cell["underline_style"] == "curly" for row in s["styles"] for cell in row), "LazyVim colored diagnostic underline")
        host.send(input=":lua Snacks.picker.files()\r")
        host.wait(lambda s: "Files" in "\n".join(s["lines"]), "Snacks file picker")
        key(host, 27)
        time.sleep(0.6)
        host.send(input=":lua Snacks.explorer()\r")
        host.wait(lambda s: "Explorer" in "\n".join(s["lines"]), "Snacks explorer")
        key(host, 27)
        time.sleep(0.6)
        host.wait(lambda s: "VERTEX_BASE" in "\n".join(s["lines"]), "return from explorer")
        host.send(input=":terminal /bin/sh -i\r")
        host.wait(lambda s: any(line.rstrip().endswith(("$", "#", ">")) for line in s["lines"]), "embedded shell started")
        host.send(input="i")
        host.wait(lambda s: s["lines"][s["cursor"]["row"]][:s["cursor"]["column"]].rstrip().endswith(("$", "#", ">")), "LazyVim embedded shell")
        host.send(paste="printf '\\nVERTEX_EMBEDDED_OK\\n'; exit")
        time.sleep(0.1)
        key(host, 13)
        host.wait(lambda s: any("VERTEX_EMBEDDED_OK" in line and "printf" not in line for line in s["lines"]), "LazyVim embedded terminal output")
        key(host, ord("\\"), control=True)
        key(host, ord("n"), control=True)
        host.send(input=":bd!\r")
        host.wait(lambda s: "VERTEX_BASE" in "\n".join(s["lines"]), "return from embedded terminal")
    marker = "VERTEX_EDIT_OK 界 é "
    if app in ("nvim", "lazyvim", "vim", "hx"):
        host.send(input="i")
    host.send(paste=marker)
    host.wait(lambda s: "VERTEX_EDIT_OK" in "\n".join(s["lines"]), f"{app} applied paste")
    if app == "emacs":
        key(host, ord("x"), control=True)
        key(host, ord("s"), control=True)
        key(host, ord("x"), control=True)
        key(host, ord("c"), control=True)
    else:
        key(host, 27)
        # A multiplexer may use legacy Escape with its configured ambiguity timer.
        time.sleep(0.6 if getattr(host, "in_tmux", False) else 0.05)
        host.send(input=":wq\r")
    host.wait(at_prompt, f"{app} exit")
    assert marker in path.read_text(), (app, path.read_text())
    shell_ready(host)


def git_tui(host, root, command):
    path = root / "change.txt"
    path.write_text("VERTEX_GIT_BASE\n")
    run("git", "-C", str(root), "add", "change.txt")
    run("git", "-C", str(root), "commit", "-qm", "fixture")
    path.write_text("VERTEX_GIT_CHANGED\n")
    host.send(input=shlex.join(command) + "\r")
    host.wait(lambda s: s["alternate"] and "change.txt" in "\n".join(s["lines"]), "lazygit file list")
    host.send(input="2")
    key(host, ord(" "))
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if "VERTEX_GIT_CHANGED" in run("git", "-C", str(root), "diff", "--cached").stdout.decode():
            break
        time.sleep(0.05)
    else:
        raise AssertionError("lazygit did not stage the fixture file")
    host.send(resize=[32, 110])
    host.wait(lambda s: s["rows"] == 32 and "change.txt" in "\n".join(s["lines"]), "lazygit resize")
    host.send(input="q")
    host.wait(at_prompt, "lazygit exit")
    shell_ready(host)


def framework(host, name, command):
    host.send(input=shlex.join(command) + "\r")
    host.text("VERTEX_FRAMEWORK_READY")
    key(host, ord("x"))
    host.text("VERTEX_FRAMEWORK_INPUT x")
    host.send(resize=[32, 100])
    host.wait(lambda s: s["rows"] == 32 and "VERTEX_FRAMEWORK_INPUT x" in "\n".join(s["lines"]), name + " resized redraw")
    host.send(input="q")
    host.wait(at_prompt, name + " exit")
    shell_ready(host)


def agent_command(app, root, env, url):
    if app == "codex":
        home = root / ".codex"
        home.mkdir()
        # The fixture process has a private HOME; no real Codex configuration is read.
        (home / "config.toml").write_text(
            'model = "vertex-test"\nmodel_provider = "vertex_fixture"\n'
            '[model_providers.vertex_fixture]\nname = "Vertex fixture"\n'
            f'base_url = "{url}/v1"\nwire_api = "responses"\nrequires_openai_auth = false\n'
            f'[projects.{json.dumps(str(root))}]\ntrust_level = "trusted"\n')
        return [app, "--no-daemon", "-s", "read-only", "-C", str(root)]
    if app == "claude":
        env.update(ANTHROPIC_BASE_URL=url, ANTHROPIC_API_KEY="vertex-fixture-key",
                   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", DISABLE_AUTOUPDATER="1")
        (root / ".claude.json").write_text(json.dumps({
            "hasCompletedOnboarding": True, "theme": "dark", "hasAcknowledgedCostThreshold": True,
            "customApiKeyResponses": {"approved": ["vertex-fixture-key"], "rejected": []},
            "projects": {str(root): {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True}}}))
        return [app, "--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--tools", "", "--permission-mode", "plan"]
    env.update(OPENCODE_DISABLE_AUTOUPDATE="true", OPENCODE_DISABLE_DEFAULT_PLUGINS="true",
               OPENAI_API_KEY="vertex-fixture-key", OPENAI_BASE_URL=url + "/v1")
    env["OPENCODE_CONFIG_CONTENT"] = json.dumps({
        "$schema": "https://opencode.ai/config.json", "model": "openai/vertex-test",
        "provider": {"openai": {"options": {"baseURL": url + "/v1", "apiKey": "vertex-fixture-key"},
                                  "models": {"vertex-test": {"name": "Vertex fixture", "limit": {"context": 32000, "output": 4096}}}}}})
    return [app, "--model", "openai/vertex-test"]


def agent(host, app, command, requests):
    host.send(input=shlex.join(command) + "\r")
    ready = {"codex": "Ask Codex", "claude": "for shortcuts", "opencode": "Ask anything"}[app]
    host.wait(lambda s: (any(line.lstrip().startswith("❯") for line in s["lines"]) if app == "claude" else ready.lower() in "\n".join(s["lines"]).lower()) and s["modes"]["bracketed_paste"], f"{app} composer", timeout=30)
    # A prompt must never equal the response marker, so echoed input cannot pass.
    host.send(paste="Answer the fixture.\nInclude a second line.")
    host.wait(lambda s: "Include a second line." in "\n".join(s["lines"]), f"{app} applied multiline paste")
    key(host, 13)
    host.wait(lambda s: MARKER in "\n".join(s["lines"]), f"{app} local streamed response", timeout=30)
    assert requests, f"{app} never contacted its local model"
    host.send(resize=[32, 100])
    host.wait(lambda s: s["rows"] == 32, f"{app} resize")
    key(host, 27)
    time.sleep(0.6 if getattr(host, "in_tmux", False) else 0.25)
    host.send(paste="/quit" if app == "codex" else "/exit")
    host.wait(lambda s: ("/quit" if app == "codex" else "/exit") in "\n".join(s["lines"]), f"{app} quit command")
    key(host, 13)
    host.wait(at_prompt, f"{app} exit", timeout=15)
    shell_ready(host)


def check(args, app, transport, root, url=None, requests=None):
    env = environment(root, args)
    command = {
        "nvim": ["nvim", "--clean", "-n"], "vim": ["vim", "-Nu", "NONE", "-n", "-i", "NONE"],
        "emacs": ["emacs", "-Q", "-nw"], "hx": ["hx"], "lazyvim": ["nvim", "-n"],
        "lazygit": ["lazygit"], "lazydocker": ["lazydocker"],
    }.get(app)
    if app in FRAMEWORKS:
        command = FRAMEWORKS[app]
    if app in ("codex", "claude", "opencode"):
        command = agent_command(app, root, env, url)
    if app == "lazyvim":
        if not args.lazyvim_fixture:
            raise AssertionError("LazyVim needs --lazyvim-fixture containing config and data snapshots")
        for name in ("config", "data"):
            shutil.copytree(args.lazyvim_fixture / name, root / name, dirs_exist_ok=True)
        plugins = root / "config/nvim/lua/plugins"
        plugins.mkdir(parents=True, exist_ok=True)
        (plugins / "vertex_fixture.lua").write_text('return {\n'
            ' {"nvim-treesitter/nvim-treesitter", build=false, opts=function(_, o) o.ensure_installed={} o.auto_install=false end},\n'
            ' {"mason-org/mason.nvim", build=false, opts=function(_, o) o.ensure_installed={} end},\n'
            '}\n')
        env["VERTEX_HOST_DETAILS"] = "1"
    if app == "lazygit":
        config = root / "config/lazygit"
        config.mkdir()
        (config / "config.yml").write_text("gui:\n  skipDiscardChangeWarning: true\ndisableStartupPopups: true\nupdate:\n  method: never\ngit:\n  autoFetch: false\n")
    if app == "lazydocker":
        if not args.docker_host:
            raise AssertionError("lazydocker requires --docker-host pointing to a disposable daemon")
        if not args.docker_host.startswith("unix://") or not Path(args.docker_host[7:]).name.startswith("vertex-"):
            raise AssertionError("use a dedicated unix://.../vertex-*.sock Docker test daemon")
        env["DOCKER_HOST"] = args.docker_host
    shell = ["/bin/sh", "-i"]
    cleanup = None
    private_runtime = None
    if transport == "tmux":
        conf = root / "tmux.conf"
        conf.write_text('set -g default-terminal "tmux-256color"\nset -g mouse on\nset -g extended-keys on\nset -as terminal-features ",xterm*:RGB:extkeys:clipboard:sync:usstyle:cstyle"\n')
        prefix = ["tmux", "-S", str(root / "tmux.sock"), "-f", str(conf)]
        shell = [*prefix, "new-session", "-s", "vertex-tui", "-c", str(root), "/bin/sh -i"]
        cleanup = [*prefix, "kill-server"]
    elif transport == "zellij":
        conf = root / "zellij.kdl"
        conf.write_text('show_startup_tips false\nshow_release_notes false\n')
        name = "vertex-tui-" + str(os.getpid()) + "-" + root.name
        shell = ["zellij", "--config", str(conf), "--session", name]
        cleanup = ["zellij", "kill-session", name]
    elif transport == "herdr":
        private_runtime = tempfile.TemporaryDirectory(prefix="vh-")
        conf = Path(private_runtime.name) / "herdr.toml"
        env["XDG_CONFIG_HOME"] = str(Path(private_runtime.name) / "config")
        conf.write_text('onboarding = false\n[update]\nversion_check = false\nmanifest_check = false\n')
        env["HERDR_CONFIG_PATH"] = str(conf)
        name = "vtx-" + str(os.getpid())
        shell = ["herdr", "--session", name]
        cleanup = ["herdr", "--session", name, "server", "stop"]
    else:
        shell = ["/bin/sh", "-c", "cd " + shlex.quote(str(root)) + "; exec /bin/sh -i"]
    if args.ssh_prefix:
        shell = [*json.loads(args.ssh_prefix), "env " + shlex.join([f"{name}={value}" for name, value in env.items()]) + " " + shlex.join(shell)]
    host = Host(args.host.resolve(), shell, env, root)
    host.in_tmux = transport != "standalone"
    try:
        host.wait(lambda s: s["lines"][s["cursor"]["row"]][:s["cursor"]["column"]].rstrip().endswith(("$", "#", ">")), "shell startup")
        host.send(input="PS1='VERTEX_PROMPT> '\r")
        host.wait(at_prompt, "fixture shell prompt")
        if app in FRAMEWORKS:
            framework(host, app, command)
        elif app in ("nvim", "vim", "emacs", "hx", "lazyvim"):
            editor(host, app, root, command)
        elif app == "lazygit":
            git_tui(host, root, command)
        elif app == "lazydocker":
            host.send(input="lazydocker\r")
            host.wait(lambda s: s["alternate"] and "vertex-tui-fixture" in "\n".join(s["lines"]), "lazydocker container list", timeout=30)
            host.send(resize=[32, 100])
            host.send(input="q")
            host.wait(at_prompt, "lazydocker exit")
            shell_ready(host)
        else:
            agent(host, app, command, requests)
        print(f"PASS {app} ({transport})", flush=True)
    except Exception:
        with contextlib.suppress(Exception):
            state = host.snapshot(details=True)
            (root / "failure.json").write_text(json.dumps(state, ensure_ascii=False, indent=2))
            report(state, root / "failure.html")
        raise
    finally:
        host.close()
        if cleanup:
            subprocess.run(cleanup, env=env, capture_output=True, timeout=5)
        if private_runtime:
            shutil.copytree(private_runtime.name, root / "herdr-runtime", dirs_exist_ok=True)
            private_runtime.cleanup()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host", type=Path)
    parser.add_argument("--test-driver", action="store_true")
    parser.add_argument("--tools-dir", type=Path)
    parser.add_argument("--apps", nargs="+", default=["nvim", "lazyvim", "vim", "emacs", "hx", "lazygit", "lazydocker", "codex", "claude", "opencode", "curses", "ink", "textual", "bubbletea"])
    parser.add_argument("--transports", nargs="+", choices=["standalone", "tmux", "zellij", "herdr"], default=["standalone", "tmux"])
    parser.add_argument("--ssh-prefix", help="JSON argv for a dedicated localhost SSH fixture")
    parser.add_argument("--require-apps", action="store_true")
    parser.add_argument("--docker-host", default=os.environ.get("VERTEX_TEST_DOCKER_HOST"))
    parser.add_argument("--lazyvim-fixture", type=Path, default=os.environ.get("VERTEX_TEST_LAZYVIM_FIXTURE"))
    parser.add_argument("--artifacts-dir", type=Path, default=os.environ.get("VERTEX_TEST_ARTIFACTS"))
    args = parser.parse_args()
    if args.ssh_prefix and args.artifacts_dir:
        args.artifacts_dir = args.artifacts_dir / "ssh"
    path = (str(args.tools_dir.resolve()) + os.pathsep if args.tools_dir else "") + os.environ["PATH"]
    with contextlib.ExitStack() as stack:
        root = args.artifacts_dir or Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="vertex-tuis-")))
        root.mkdir(parents=True, exist_ok=True)
        for app in args.apps:
            binary = "nvim" if app == "lazyvim" else app
            if app in FRAMEWORKS:
                binary = FRAMEWORKS[app][0]
            if not shutil.which(binary, path=path) or (app == "lazydocker" and not args.docker_host):
                if args.require_apps:
                    raise AssertionError(f"required application unavailable: {app}")
                print(f"SKIP {app}: executable or isolated Docker endpoint unavailable", flush=True)
                continue
            for transport in args.transports:
                case = root / (app + "-" + transport)
                case.mkdir()
                if app in ("codex", "claude", "opencode"):
                    with model_server() as (url, requests):
                        check(args, app, transport, case, url, requests)
                else:
                    check(args, app, transport, case)


if __name__ == "__main__":
    main()
