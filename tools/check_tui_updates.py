"""Scheduled maintenance signal; pins change only after reviewing test results."""
import json
from pathlib import Path
import urllib.request

root = Path(__file__).resolve().parents[1]
pins = json.loads((root / "tests/tui-tools.json").read_text())
changed = []
for name, repo in {"nvim": "neovim/neovim", "hx": "helix-editor/helix", "lazygit": "jesseduffield/lazygit", "lazydocker": "jesseduffield/lazydocker"}.items():
    request = urllib.request.Request("https://api.github.com/repos/" + repo + "/releases/latest", headers={"User-Agent": "Vertex compatibility"})
    with urllib.request.urlopen(request, timeout=30) as response:
        latest = json.load(response)["tag_name"].removeprefix("v")
    print(f"{name}: tested {pins[name]['version']}, released {latest}")
    if latest != pins[name]["version"]:
        changed.append(name)
packages = json.loads((root / "tests/tui-fixtures/package.json").read_text())["dependencies"]
for name in ("@openai/codex", "@anthropic-ai/claude-code", "opencode-ai", "ink"):
    with urllib.request.urlopen("https://registry.npmjs.org/" + name + "/latest", timeout=30) as response:
        latest = json.load(response)["version"]
    print(f"{name}: tested {packages[name]}, released {latest}")
    if latest != packages[name]:
        changed.append(name)
if changed:
    raise SystemExit("Compatibility pins need validation against: " + ", ".join(changed))
