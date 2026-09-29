#!/usr/bin/env bash
set -eo pipefail

project="godot"
godot_bin="${GODOT_BIN:-godot}"
log_dir="${GODOT_QUALITY_GATE_LOG_DIR:-}"
smoke_scripts=()

usage() {
  cat <<'USAGE'
Usage: godot_quality_gate.sh [--project PATH] [--godot-bin PATH] [--smoke-script PATH]...

Runs clean import, compile, and optional headless scripts. Fails on non-zero exit,
SCRIPT ERROR, ERROR:, missing resources, or parse failures in Godot logs.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) project="${2:?missing project}"; shift 2 ;;
    --godot-bin) godot_bin="${2:?missing godot binary}"; shift 2 ;;
    --smoke-script) smoke_scripts+=("${2:?missing smoke script}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$log_dir" ]; then
  log_dir="$(mktemp -d)"
else
  mkdir -p "$log_dir"
fi

run_check() {
  local label="$1"
  shift
  local log_file="$log_dir/$label.log"
  echo "[godot-quality] $label: $*" >&2
  set +e
  "$@" 2>&1 | tee "$log_file"
  local status="${PIPESTATUS[0]}"
  set -e
  if [ "$status" -ne 0 ]; then
    echo "[godot-quality] $label exited $status ($log_file)" >&2
    exit "$status"
  fi
  if rg -n "^(SCRIPT ERROR|ERROR):|Parse Error|Failed to load script|Could not load resource|No loader found for resource" "$log_file" >/dev/null; then
    echo "[godot-quality] $label reported engine errors ($log_file)" >&2
    rg -n "^(SCRIPT ERROR|ERROR):|Parse Error|Failed to load script|Could not load resource|No loader found for resource" "$log_file" >&2 || true
    exit 1
  fi
}

run_check import "$godot_bin" --headless --path "$project" --import --quit
run_check compile "$godot_bin" --headless --path "$project" --quit-after 2

index=0
for smoke_script in "${smoke_scripts[@]}"; do
  index=$((index + 1))
  run_check "smoke_$index" "$godot_bin" --headless --path "$project" --script "res://$smoke_script"
done

echo "[godot-quality] PASS logs=$log_dir"
