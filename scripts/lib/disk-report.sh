#!/usr/bin/env bash
# Report disk usage delta since last checkpoint (or baseline).
# Usage: disk-report.sh <label> [--baseline]
set -euo pipefail

LABEL="${1:?Usage: disk-report.sh <label> [--baseline]}"
STATE_DIR="${EAI_STATE_DIR:-$HOME/.cache/amdeai}"
mkdir -p "$STATE_DIR"
BASELINE="$STATE_DIR/df-baseline.txt"
LAST="$STATE_DIR/df-last.txt"
LOG="$STATE_DIR/disk-log.txt"

root_used_bytes() {
  df -B1 / | awk 'NR==2 {print $3}'
}

snapshot() {
  echo "# $(date -Iseconds) $LABEL"
  df -h / /home/magnus/projects 2>/dev/null
  echo "--- root used bytes ---"
  root_used_bytes
  if [[ -d "${EAI_BUILD_DIR:-$HOME/eai-build}" ]]; then
    echo "--- eai-build ---"
    du -sh "${EAI_BUILD_DIR:-$HOME/eai-build}" 2>/dev/null || true
  fi
  if command -v docker &>/dev/null; then
    echo "--- docker images ---"
    docker system df 2>/dev/null | head -5 || true
  fi
}

if [[ "${2:-}" == "--check-only" ]]; then
  FREE_KB=$(df / | awk 'NR==2 {print $4}')
  FREE_GB=$((FREE_KB / 1024 / 1024))
  MIN_FREE_GB="${EAI_MIN_FREE_GB:-15}"
  echo "Disk check: ${FREE_GB} GiB free (min ${MIN_FREE_GB} GiB)"
  [[ $FREE_GB -ge $MIN_FREE_GB ]] || exit 2
  exit 0
fi

if [[ "${2:-}" == "--baseline" ]]; then
  root_used_bytes > "$BASELINE"
  root_used_bytes > "$LAST"
  snapshot >> "$LOG"
  echo "[$LABEL] Baseline recorded."
  exit 0
fi

CURRENT=$(mktemp)
root_used_bytes > "$CURRENT"
snapshot >> "$LOG"

echo ""
echo "========== Disk report: $LABEL =========="
df -h / /home/magnus/projects 2>/dev/null
if [[ -d "${EAI_BUILD_DIR:-$HOME/eai-build}" ]]; then
  echo "eai-build: $(du -sh "${EAI_BUILD_DIR:-$HOME/eai-build}" 2>/dev/null | cut -f1)"
fi

if [[ -f "$LAST" ]]; then
  echo "--- delta since previous step ---"
  p_u=$(head -1 "$LAST" | tr -dc '0-9')
  c_u=$(head -1 "$CURRENT" | tr -dc '0-9')
  d=$(( (c_u - p_u) / 1024 / 1024 ))
  if [[ $d -gt 0 ]]; then
    echo "  /: +${d} MiB used"
  elif [[ $d -lt 0 ]]; then
    echo "  /: ${d} MiB (freed)"
  else
    echo "  /: no change"
  fi
fi

cp "$CURRENT" "$LAST"
FREE_KB=$(df / | awk 'NR==2 {print $4}')
FREE_GB=$((FREE_KB / 1024 / 1024))
MIN_FREE_GB="${EAI_MIN_FREE_GB:-15}"
echo "Free on /: ${FREE_GB} GiB (minimum required: ${MIN_FREE_GB} GiB)"
if [[ $FREE_GB -lt $MIN_FREE_GB ]]; then
  echo "STOP: Disk space below ${MIN_FREE_GB} GiB — pausing build. Free space before continuing."
  echo "=========================================="
  exit 2
fi
if [[ $FREE_GB -lt 50 ]]; then
  echo "WARNING: less than 50 GiB free on root filesystem."
fi
echo "=========================================="
echo ""
