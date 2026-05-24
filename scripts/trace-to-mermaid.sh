#!/usr/bin/env bash
# Read a TLC log on stdin; emit Markdown with a mermaid sequenceDiagram.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/trace_to_mermaid.py"
