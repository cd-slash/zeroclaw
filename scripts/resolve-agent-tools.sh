#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <agent-name>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_NAME="$1"
AGENT_DIR="${PROJECT_DIR}/.agents/${AGENT_NAME}"
TOOLS_TOML="${AGENT_DIR}/tools.toml"
BUILD_TOOLS_DIR="${AGENT_DIR}/.build-tools"

if [[ ! -d "$AGENT_DIR" ]]; then
  echo "[resolve-agent-tools] Agent directory not found: $AGENT_DIR" >&2
  exit 1
fi

rm -rf "$BUILD_TOOLS_DIR"
mkdir -p "$BUILD_TOOLS_DIR"

if [[ ! -f "$TOOLS_TOML" ]]; then
  echo "[resolve-agent-tools] No tools.toml for '${AGENT_NAME}', using empty toolset"
  exit 0
fi

python3 - "$TOOLS_TOML" "$BUILD_TOOLS_DIR" "$PROJECT_DIR" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys
import tomllib
import urllib.parse
import urllib.request

tools_toml = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
project_dir = pathlib.Path(sys.argv[3])

with tools_toml.open("rb") as f:
    data = tomllib.load(f)

entries = data.get("tool", [])
if isinstance(entries, dict):
    entries = [entries]
if not isinstance(entries, list):
    raise SystemExit("tools.toml: 'tool' must be a list of [[tool]] tables")

def norm_name(name: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in ("-", "_", ".") else "-" for ch in name.strip())
    return cleaned or "tool"

installed = 0
seen_bins: set[str] = set()

for idx, entry in enumerate(entries, start=1):
    if not isinstance(entry, dict):
        raise SystemExit(f"tools.toml: [[tool]] entry #{idx} is not a table")

    enabled = bool(entry.get("enabled", True))
    if not enabled:
        continue

    name = str(entry.get("name", "")).strip()
    if not name:
        raise SystemExit(f"tools.toml: [[tool]] entry #{idx} missing 'name'")

    source = str(entry.get("source", "path")).strip().lower()
    description = str(entry.get("description", "No description provided.")).strip()
    sha256_expected = str(entry.get("sha256", "")).strip().lower()

    raw_bytes: bytes
    default_binary_name: str

    if source in ("path", "local"):
        src_path_raw = str(entry.get("path", "")).strip()
        if not src_path_raw:
            raise SystemExit(f"tools.toml: tool '{name}' missing 'path'")
        expanded = os.path.expanduser(os.path.expandvars(src_path_raw))
        src_path = pathlib.Path(expanded)
        if not src_path.is_absolute():
            src_path = project_dir / src_path
        if not src_path.is_file():
            raise SystemExit(f"tools.toml: tool '{name}' path not found: {src_path}")
        raw_bytes = src_path.read_bytes()
        default_binary_name = src_path.name
    elif source in ("url", "remote"):
        url = str(entry.get("url", "")).strip()
        if not url:
            raise SystemExit(f"tools.toml: tool '{name}' missing 'url'")
        with urllib.request.urlopen(url, timeout=60) as resp:
            if resp.status >= 400:
                raise SystemExit(f"tools.toml: failed downloading '{name}' from {url}: HTTP {resp.status}")
            raw_bytes = resp.read()
        default_binary_name = pathlib.Path(urllib.parse.urlparse(url).path).name or norm_name(name)
    else:
        raise SystemExit(f"tools.toml: tool '{name}' has unsupported source '{source}'")

    if sha256_expected:
        digest = hashlib.sha256(raw_bytes).hexdigest()
        if digest != sha256_expected:
            raise SystemExit(
                f"tools.toml: sha256 mismatch for '{name}': expected {sha256_expected}, got {digest}"
            )

    binary_name = str(entry.get("binary", "")).strip() or default_binary_name or norm_name(name)
    binary_name = norm_name(binary_name)
    if binary_name in seen_bins:
        raise SystemExit(f"tools.toml: duplicate binary target '{binary_name}'")
    seen_bins.add(binary_name)

    dest = out_dir / binary_name
    dest.write_bytes(raw_bytes)
    mode = dest.stat().st_mode
    dest.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    meta = out_dir / f".{binary_name}.tool"
    meta.write_text(
        f"name={name}\n"
        f"description={description}\n"
        f"binary={binary_name}\n"
        f"source={source}\n",
        encoding="utf-8",
    )
    installed += 1

print(f"[resolve-agent-tools] Installed {installed} tool(s) from {tools_toml}")
(out_dir / ".gitkeep").write_text("", encoding="utf-8")
PY
