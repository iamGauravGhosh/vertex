"""Real PTY/outer-grid checks. Multiplexers are test dependencies only."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import time


class Host:
    def __init__(self, executable, command, environment, root):
        self.log = (root / "host.log").open("w+")
        environment = dict(environment, VERTEX_HOST_COMMAND=json.dumps(command), VERTEX_HOST_TRACE=str(root / "pty.trace"))
        self.process = subprocess.Popen(
            [str(executable), *([] if environment.get("VERTEX_HOST_TEST_DRIVER") == "1" else command)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.log, env=environment, cwd=root, text=True, bufsize=1,
        )

    def send(self, **command):
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()

    def snapshot(self, details=False):
        self.send(snapshot=True, details=details)
        if not select.select([self.process.stdout], [], [], 5)[0]:
            self.log.seek(0)
            raise AssertionError(f"host snapshot timeout: {self.log.read()}")
        line = self.process.stdout.readline()
        if not line:
            self.log.seek(0)
            raise AssertionError(f"host exited {self.process.poll()}: {self.log.read()}")
        return json.loads(line)

    def wait(self, predicate, description, timeout=15):
        deadline = time.monotonic() + timeout
        state = None
        while time.monotonic() < deadline:
            state = self.snapshot()
            if predicate(state):
                return state
            time.sleep(0.03)
        summary = {key: value for key, value in (state or {}).items() if key not in ("styles", "widths", "graphemes")}
        raise AssertionError(f"{description}: {json.dumps(summary, ensure_ascii=False)}")

    def text(self, needle):
        return self.wait(lambda state: needle in "\n".join(state["lines"]), needle)

    def close(self):
        if self.process.poll() is None:
            with contextlib.suppress(BrokenPipeError):
                self.send(close=True)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        with contextlib.suppress(BrokenPipeError):
            self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()


def shell_checks(host, kind):
    host.wait(lambda s: s["lines"][s["cursor"]["row"]][:s["cursor"]["column"]].rstrip().endswith(("$", "#")), "interactive shell ready")
    host.send(input="printf '\\033[38;2;17;129;253mVERTEX_COLOR\\033[0m \\347\\225\\214 e\\314\\201 \\342\\224\\214\\342\\224\\200\\342\\224\\220\\nVERTEX_READY\\n'\r")
    host.text("VERTEX_READY")
    # A command echo is insufficient: verify a line beginning with actual output.
    state = host.wait(lambda s: any("VERTEX_COLOR " in line and "printf" not in line for line in s["lines"]), "colored Unicode output")
    expected = "界 é ┌─┐"
    if kind in ("zellij", "nested") and b"\xcc\x81" not in Path(host.log.name).with_name("pty.trace").read_bytes():
        # Zellij 0.45.1 omits this combining scalar from its outer output.
        # Still require Vertex to preserve it whenever it is actually emitted.
        expected = "界 e ┌─┐"
    assert any(expected in line for line in state["lines"]), state
    host.send(resize=[32, 100])
    host.send(input="printf 'SIZE='; stty size; printf 'RESIZED_OK\\n'\r")
    host.wait(lambda s: s["rows"] == 32 and s["columns"] == 100 and any("SIZE=" in line and "printf" not in line for line in s["lines"]), "resized grid and PTY")
    host.send(key={"code": ord("p"), "text": "p"})
    host.send(input="rintf 'KEY_OK\\n'\r")
    host.wait(lambda s: any("KEY_OK" in line and "printf" not in line for line in s["lines"]), "encoded keyboard input")
    host.send(paste="printf 'PASTE_OK\\n'")
    # Input transactions are serialized in host protocol order; send Enter after paste.
    host.send(input="\r")
    host.wait(lambda s: any("PASTE_OK" in line and "printf" not in line for line in s["lines"]), "paste transaction")


def stress_tmux(host, prefix, environment):
    """Exercise an interactive pane beside 7, then 31 live output producers."""
    def control(*arguments):
        return subprocess.check_output([*prefix, *arguments], env=environment, text=True, timeout=5).strip()

    host.send(resize=[96, 160])
    host.wait(lambda s: s["rows"] == 96, "stress geometry")
    producer = shlex.join([sys.executable, str(Path(__file__).with_name("multiplexer_workload.py").resolve())])
    control("respawn-pane", "-k", "-t", "vertex:0.1", producer)
    count = 2
    for target in (8, 32):
        while count < target:
            control("split-window", "-d", "-t", "vertex:0.0", producer)
            control("select-layout", "-t", "vertex:0", "tiled")
            count += 1
        control("select-pane", "-t", "vertex:0.0")
        for sample in range(5):
            marker = f"BUSY_{target}_{sample}_OK"
            host.send(input=f"printf '{marker}\\n'\r")
            host.wait(lambda s: any(marker in line and "printf" not in line for line in s["lines"]), f"input beside {target - 1} busy panes")
        print(f"tmux: {target} panes, concurrent log output and interactive input passed", flush=True)


def check(executable, kind, root, base_environment, remote_prefix=None):
    config = root / "config"
    config.mkdir()
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700)
    environment = dict(base_environment, SHELL="/bin/sh", LANG="C.UTF-8", LC_ALL="C.UTF-8", XDG_CONFIG_HOME=str(config),
                       XDG_CACHE_HOME=str(root / "cache"), XDG_DATA_HOME=str(root / "data"),
                       XDG_RUNTIME_DIR=str(runtime), ZELLIJ_AUTO_ATTACH="false")
    environment.pop("TMUX", None)
    environment.pop("ZELLIJ", None)
    environment.pop("HERDR_ENV", None)
    cleanup = None
    nested_cleanup = None
    if kind == "standalone":
        command = ["/bin/sh", "-i"]
    elif kind in ("tmux", "nested"):
        conf = root / "tmux.conf"
        conf.write_text('set -g mouse on\nset -g set-clipboard on\nset -as terminal-features ",xterm*:RGB:clipboard:extkeys:sync:margins"\nset -g extended-keys on\n')
        prefix = ["tmux", "-S", str(root / "tmux.sock"), "-f", str(conf)]
        command = [*prefix, "new-session", "-s", "vertex"]
        cleanup = [*prefix, "kill-server"]
        if kind == "nested":
            nested_conf = root / "zellij.kdl"
            nested_conf.write_text('show_startup_tips false\nshow_release_notes false\n')
            nested_name = "vertex-nested-" + str(os.getpid())
            command.append(shlex.join(["zellij", "--config", str(nested_conf), "--session", nested_name]))
            nested_cleanup = ["zellij", "kill-session", nested_name]
    elif kind == "zellij":
        conf = root / "zellij.kdl"
        conf.write_text('show_startup_tips false\nshow_release_notes false\n')
        name = "vertex-test-" + str(os.getpid()) + "-" + root.name
        command = ["zellij", "--config", str(conf), "--session", name]
        cleanup = ["zellij", "kill-session", name]
    elif kind == "herdr":
        (config / "herdr").mkdir()
        (config / "herdr" / "config.toml").write_text('onboarding = false\n[update]\nversion_check = false\nmanifest_check = false\n')
        environment["HERDR_CONFIG_PATH"] = str(config / "herdr" / "config.toml")
        name = "vertex-test-" + str(os.getpid()) + "-" + root.name
        command = ["herdr", "--session", name]
        cleanup = ["herdr", "--session", name, "server", "stop"]
    else:
        raise AssertionError(kind)
    if remote_prefix:
        # The isolated server is on the same machine: share only this test's paths.
        assignments = [f"{key}={shlex.quote(environment[key])}" for key in
                       ("SHELL", "LANG", "LC_ALL", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR", "PATH", "HERDR_CONFIG_PATH") if key in environment]
        command = [*remote_prefix, "env " + " ".join(assignments) + " " + shlex.join(command)]
    host = Host(executable, command, environment, root)
    try:
        shell_checks(host, kind)
        if kind in ("standalone", "tmux"):
            host.send(input="printf '\\033]52;c;dmVydGV4LWNvcHk=\\007'\r")
            host.wait(lambda s: s["clipboard"] == "vertex-copy", "OSC 52 clipboard write")
        if kind == "tmux":
            # Exercise real prefix handling and pane borders in the outer grid.
            host.send(input="\x02%")
            host.send(input="printf 'SECOND_PANE_OK\\n'\r")
            host.wait(lambda s: any("SECOND_PANE_OK" in line and "printf" not in line for line in s["lines"]), "split pane")
            host.send(input="\x02o")
            host.send(input="printf 'FIRST_PANE_OK\\n'\r")
            host.wait(lambda s: any("FIRST_PANE_OK" in line and "printf" not in line for line in s["lines"]), "pane navigation")
            # Click the right pane through the negotiated mouse protocol.
            host.send(pointer={"kind": "press", "button": 0, "column": 75, "row": 2})
            host.send(pointer={"kind": "release", "button": 0, "column": 75, "row": 2})
            host.send(input="printf 'MOUSE_PANE_OK\\n'\r")
            host.wait(lambda s: any("MOUSE_PANE_OK" in line and "printf" not in line for line in s["lines"]), "mouse pane focus")
            host.send(input="\x02d")
            time.sleep(0.15)
            host.close()
            attach = [*prefix, "attach-session", "-t", "vertex"]
            if remote_prefix:
                attach = [*remote_prefix, "env " + " ".join(assignments) + " " + shlex.join(attach)]
            host = Host(executable, attach, environment, root)
            host.text("FIRST_PANE_OK")
            if not remote_prefix:
                stress_tmux(host, prefix, environment)
        elif kind == "zellij":
            subprocess.run(["zellij", "--session", name, "action", "new-pane", "--direction", "right"], env=environment, check=True, capture_output=True, timeout=5)
            host.wait(lambda s: s["lines"][s["cursor"]["row"]][:s["cursor"]["column"]].rstrip().endswith(("$", "#")), "split shell ready")
            host.send(input="printf 'ZELLIJ_SPLIT_OK\\n'\r")
            host.wait(lambda s: any("ZELLIJ_SPLIT_OK" in line and "printf" not in line for line in s["lines"]), "Zellij split")
            subprocess.run(["zellij", "--session", name, "action", "detach"], env=environment, check=True, capture_output=True, timeout=5)
            time.sleep(0.1)
            host.close()
            attach = ["zellij", "--config", str(conf), "attach", name]
            if remote_prefix:
                attach = [*remote_prefix, "env " + " ".join(assignments) + " " + shlex.join(attach)]
            host = Host(executable, attach, environment, root)
            host.text("ZELLIJ_SPLIT_OK")
        elif kind == "herdr":
            host.send(input="\x02v")
            time.sleep(0.2)
            host.send(input="printf 'HERDR_SPLIT_OK\\n'\r")
            host.wait(lambda s: any("HERDR_SPLIT_OK" in line and "printf" not in line for line in s["lines"]), "Herdr split")
            host.send(input="\x02q")
            time.sleep(0.2)
            host.close()
            host = Host(executable, command, environment, root)
            host.text("HERDR_SPLIT_OK")
        print(f"{kind} {'SSH' if remote_prefix else 'local'}: outer grid, Unicode, resize, keys, paste passed", flush=True)
    finally:
        host.close()
        if cleanup:
            subprocess.run(cleanup, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        if nested_cleanup:
            subprocess.run(nested_cleanup, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host", type=Path)
    parser.add_argument("--require-multiplexers", action="store_true")
    parser.add_argument("--test-driver", action="store_true", help="use a zig test host instead of the CI executable")
    parser.add_argument("--tools-dir", type=Path)
    parser.add_argument("--artifacts-dir", type=Path)
    parser.add_argument("--ssh-prefix", help="JSON argv for an isolated SSH server, e.g. ssh -tt -F config host")
    args = parser.parse_args()
    executable = args.host.resolve()
    remote_prefix = json.loads(args.ssh_prefix) if args.ssh_prefix else None
    environment = dict(os.environ)
    if args.tools_dir:
        environment["PATH"] = str(args.tools_dir.resolve()) + os.pathsep + environment["PATH"]
    if args.test_driver:
        environment["VERTEX_HOST_TEST_DRIVER"] = "1"
    temporary_root = contextlib.nullcontext(str(args.artifacts_dir)) if args.artifacts_dir else tempfile.TemporaryDirectory(prefix="vertex-multiplexers-")
    with temporary_root as temporary:
        root = Path(temporary)
        root.mkdir(parents=True, exist_ok=True)
        kinds = ["standalone", "tmux", "zellij", "herdr"]
        if shutil.which("tmux", path=environment["PATH"]) and shutil.which("zellij", path=environment["PATH"]):
            kinds.append("nested")
        for kind in kinds:
            if kind not in ("standalone", "nested") and not shutil.which(kind, path=environment["PATH"]):
                if args.require_multiplexers:
                    raise AssertionError(f"required test dependency missing: {kind}")
                print(f"SKIP {kind}: executable unavailable")
                continue
            case = root / kind
            case.mkdir()
            check(executable, kind, case, environment, remote_prefix)


if __name__ == "__main__":
    main()
