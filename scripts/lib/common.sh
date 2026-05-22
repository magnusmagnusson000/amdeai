#!/usr/bin/env bash
set -euo pipefail

EAI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EAI_BUILD_DIR="${EAI_BUILD_DIR:-$HOME/eai-build}"
EAI_VENV="${EAI_VENV:-/home/magnus/projects/venvs/amd}"
export EAI_BUILD_DIR EAI_VENV
export PATH="${GO_ROOT:-$HOME/.local/go}/bin:${HOME}/go/bin:${HOME}/.local/bin:${PATH}"
export EAI_FORCE_REBUILD="${EAI_FORCE_REBUILD:-1}"

# shellcheck source=force-build.sh
source "$EAI_ROOT/scripts/lib/force-build.sh"

log_source_tree() {
  local dir="$1"
  echo "--- Source tree (top level): $dir ---"
  if [[ -d "$dir" ]]; then
    ls -la "$dir" | head -25
    echo "Read call flow: $EAI_ROOT/docs/call-flows/"
  fi
}

disk_report() {
  bash "$EAI_ROOT/scripts/lib/disk-report.sh" "$@" || {
    local rc=$?
    if [[ $rc -eq 2 ]]; then
      echo "Build paused at disk guard (${EAI_MIN_FREE_GB:-15} GiB minimum)."
      exit 2
    fi
    return $rc
  }
}

check_disk_before_step() {
  local label="${1:-step}"
  bash "$EAI_ROOT/scripts/lib/disk-report.sh" "precheck-${label}" --check-only
}

activate_venv() {
  # shellcheck source=/dev/null
  source "$EAI_VENV/bin/activate"
}

my_ip() {
  hostname -I | awk '{print $1}'
}

domain() {
  echo "$(my_ip).nip.io"
}

# Timestamped backups under $EAI_ROOT/backups/<step>/ (machine-local; do not commit).
eai_backup_init() {
  local step="${1:-step}"
  EAI_BACKUP_DIR="$EAI_ROOT/backups/${step}/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$EAI_BACKUP_DIR"
  echo "Backup directory: $EAI_BACKUP_DIR"
}

eai_backup_file() {
  local src="$1"
  local dest_name="${2:-$(basename "$src")}"
  [[ -n "${EAI_BACKUP_DIR:-}" ]] || return 0
  if [[ -r "$src" ]]; then
    cp -a "$src" "$EAI_BACKUP_DIR/$dest_name"
  elif sudo -n test -r "$src" 2>/dev/null; then
    sudo cp -a "$src" "$EAI_BACKUP_DIR/$dest_name"
    sudo chown "$(id -u):$(id -g)" "$EAI_BACKUP_DIR/$dest_name" 2>/dev/null || true
  else
    return 0
  fi
  echo "Backed up: $src -> $EAI_BACKUP_DIR/$dest_name"
}
