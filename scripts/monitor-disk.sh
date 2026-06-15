#!/usr/bin/env bash
# Monitor root filesystem free space while Qwen deploy E2E runs.
LOG="${1:-/tmp/qwen-deploy-disk.log}"
INTERVAL="${2:-60}"
echo "=== disk monitor started $(date -Iseconds) interval=${INTERVAL}s ===" | tee "$LOG"
while true; do
  df -h / | tail -1 | tee -a "$LOG"
  FREE_GB=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  if [[ "$FREE_GB" -lt 15 ]]; then
    echo "WARNING: low disk ${FREE_GB} GiB at $(date -Iseconds)" | tee -a "$LOG"
  fi
  if ! pgrep -f "test_qwen_deploy_confirm_full" >/dev/null 2>&1; then
    echo "=== pytest finished $(date -Iseconds) ===" | tee -a "$LOG"
    break
  fi
  sleep "$INTERVAL"
done
