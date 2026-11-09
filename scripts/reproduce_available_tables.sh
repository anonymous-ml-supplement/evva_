#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/controlled_openclaw/code/check_table1.py"
python3 "$ROOT/live_web_agent/analysis/check_paper_tables.py"
