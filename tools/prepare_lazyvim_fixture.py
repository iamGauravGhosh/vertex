"""Prepare a pinned LazyVim test home. Never reads or modifies user dotfiles."""
import argparse
import json
from pathlib import Path
import os
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("destination", type=Path)
args = parser.parse_args()
source = Path(__file__).resolve().parents[1] / "tests/lazyvim"
root = args.destination.resolve()
config = root / "config/nvim"
shutil.copytree(source, config, dirs_exist_ok=True)
lazy = root / "data/nvim/lazy/lazy.nvim"
subprocess.run(["git", "clone", "--filter=blob:none", "--no-checkout", "https://github.com/folke/lazy.nvim.git", str(lazy)], check=True, timeout=90)
commit = json.loads((config / "lazy-lock.json").read_text())["lazy.nvim"]["commit"]
subprocess.run(["git", "-C", str(lazy), "checkout", "--detach", commit], check=True, timeout=90)
environment = dict(os.environ, XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"),
                   XDG_STATE_HOME=str(root / "state"), XDG_CACHE_HOME=str(root / "cache"), NVIM_LOG_FILE=str(root / "nvim.log"))
subprocess.run(["nvim", "--headless", "-u", str(config / "init.lua"), "+Lazy! restore", "+qa"], env=environment, check=True, timeout=300)
print("Pinned LazyVim fixture prepared:", root)
