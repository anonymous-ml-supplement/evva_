#!/usr/bin/env bash
set -u
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/runtime_root"
export ROOT
export STREAM_04K="$ROOT/source_stream/04k_stream"
export CONSTRUCTOR="$ROOT/constructor"
export GUARDED_RUNNER="$ROOT/runner/w12_primary_frozen_paired_branch_b2_continuation_debug.py"
export OVERRIDE="$ROOT/configs/agent_configs_runtime_override.py"
export IMAGE="${IMAGE:-evva-w12-source-aligned-agentlab:0.4.2-bg0.14.3-runtime-compatible}"
export REDDIT_IMAGE="${REDDIT_IMAGE:-am1n3e/webarena-verified-reddit:latest}"
export ENV_FILE="${ENV_FILE:-$HERE/../environment/env.docker}"
export RUN_DIR="${RUN_DIR:-$HERE/run_output}"
export OUT="${OUT:-$RUN_DIR}"
mkdir -p "$RUN_DIR" "$OUT"
echo "CURRENT=LIVE_FULL180_GPT5_MINI"
echo "MODEL=openai/gpt-5-mini-2025-08-07"
echo "EXPECTED_BRANCHES=180"
echo "ROOT=$ROOT"
echo "OUT=$OUT"
python3 "$ROOT/runner/run_step5b_04k_full180_docker_runtime_heartbeat.py"
rc=$?
echo "RETURN_CODE=$rc"
exit "$rc"
