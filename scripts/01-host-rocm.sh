#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "01-host-rocm"
eai_backup_init "01-host-rocm"

# Guide defaults (used only when a parameter is not already on the cmdline).
readonly EAI_GRUB_GUIDE_GTT=131072
readonly EAI_GRUB_GUIDE_TTM=33554432

# Merge ROCm-related kernel params into GRUB_CMDLINE_LINUX_DEFAULT without wiping
# unrelated tokens (e.g. amdgpu.dcdebugmask). Keeps existing gttsize/pages_limit
# when set so a conservative RAM margin is preserved.
merge_grub_cmdline() {
  local current="$1"
  local apply_guide="${2:-1}"
  local -a tokens=()
  local -a out=()
  local tok key gtt="" ttm="" iommu="" has_iommu=0

  if [[ -n "$current" ]]; then
    read -ra tokens <<< "$current"
  fi

  if [[ "$apply_guide" == "1" ]]; then
    for tok in "${tokens[@]}"; do
      case "$tok" in
        amdgpu.gttsize=*) gtt="${tok#*=}" ;;
        ttm.pages_limit=*) ttm="${tok#*=}" ;;
        amd_iommu=*) iommu="${tok#*=}" ;;
      esac
    done
    [[ -z "$gtt" ]] && gtt="$EAI_GRUB_GUIDE_GTT"
    [[ -z "$ttm" ]] && ttm="$EAI_GRUB_GUIDE_TTM"
    iommu="off"

    for tok in "${tokens[@]}"; do
      if [[ "$tok" == *=* ]]; then
        key="${tok%%=*}"
        case "$key" in
          amd_iommu|amdgpu.gttsize|ttm.pages_limit) continue ;;
        esac
      fi
      out+=("$tok")
    done
    out+=(amd_iommu="$iommu" "amdgpu.gttsize=$gtt" "ttm.pages_limit=$ttm")
    printf '%s' "${out[*]}"
    return 0
  fi

  for tok in "${tokens[@]}"; do
    [[ "$tok" == amd_iommu=* ]] && has_iommu=1
    out+=("$tok")
  done
  if [[ $has_iommu -eq 0 ]]; then
    out+=(amd_iommu=off)
  fi
  printf '%s' "${out[*]}"
}

echo "=== 01-host-rocm (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="
NEEDS_REBOOT=0

KVER=$(uname -r | cut -d. -f1-2)
if awk "BEGIN {exit !($KVER >= 6.14)}" 2>/dev/null; then
  echo "Kernel $KVER — HWE optional."
else
  sudo apt install -y linux-oem-24.04d || true
  NEEDS_REBOOT=1
fi

GRUB_FILE=/etc/default/grub
if [[ -f "$GRUB_FILE" ]] && sudo -n true 2>/dev/null; then
  eai_backup_file "$GRUB_FILE" default.grub
  CURRENT=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//;s/"$//')
  if [[ "${EAI_GRUB_APPLY_GUIDE_VALUES:-1}" == "1" ]]; then
    WANT=$(merge_grub_cmdline "$CURRENT" 1)
    echo "GRUB merge (guide): preserving existing gttsize/pages_limit when set."
  else
    WANT=$(merge_grub_cmdline "$CURRENT" 0)
    echo "GRUB merge: append amd_iommu=off only if missing."
  fi
  if [[ "$CURRENT" != "$WANT" ]]; then
    sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$WANT\"|" "$GRUB_FILE"
    sudo update-grub
    NEEDS_REBOOT=1
    echo "GRUB updated: $WANT"
  else
    echo "GRUB unchanged: $CURRENT"
  fi
fi

# Always configure apt repo and reinstall ROCm when forcing
if sudo -n true 2>/dev/null; then
  sudo mkdir -p /etc/apt/keyrings
  eai_backup_file /etc/apt/keyrings/rocm.gpg rocm.gpg
  eai_backup_file /etc/apt/sources.list.d/rocm.list rocm.list
  eai_backup_file /etc/apt/preferences.d/rocm-pin-600 rocm-pin-600
  wget -q https://repo.radeon.com/rocm/rocm.gpg.key -O - | \
    gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null
  sudo tee /etc/apt/sources.list.d/rocm.list << 'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2.3 noble main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/7.2.3/ubuntu noble main
EOF
  sudo tee /etc/apt/preferences.d/rocm-pin-600 << 'EOF'
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF
  sudo apt update
  if eai_force_enabled; then
    sudo apt install -y --reinstall rocm || sudo apt install -y rocm
  else
    sudo apt install -y rocm
  fi
  sudo usermod -aG render,video "$USER" || true
  NEEDS_REBOOT=1
fi

eai_backup_file /etc/environment environment
for line in \
  'HSA_OVERRIDE_GFX_VERSION=11.5.1' \
  'PYTORCH_TUNABLEOP_ENABLED=1' \
  'TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1'; do
  key="${line%%=*}"
  if sudo -n grep -q "^${key}=" /etc/environment 2>/dev/null; then
    sudo sed -i "/^${key}=/d" /etc/environment
  fi
  if sudo -n tee -a /etc/environment <<<"$line" 2>/dev/null; then
    NEEDS_REBOOT=1
  else
    eai_backup_file "$HOME/.bashrc" bashrc
    grep -q "^export ${key}=" ~/.bashrc 2>/dev/null || echo "export $line" >> ~/.bashrc
    export "$line"
  fi
done

export PATH="${PATH}:/opt/rocm/bin"
rocminfo | grep -E "Marketing|gfx" | head -8 || true
rocm-smi --showmeminfo vram 2>/dev/null | { head -5 || true; }

log_source_tree "/opt/rocm"
echo "Call flow: $EAI_ROOT/docs/call-flows/01-rocm-host.md"

disk_report "01-host-rocm-done"
if [[ "${NEEDS_REBOOT:-0}" -eq 1 ]]; then
  echo "REBOOT REQUIRED after ROCm/GRUB changes."
fi
if [[ -n "${EAI_BACKUP_DIR:-}" ]]; then
  echo "Config backups: $EAI_BACKUP_DIR"
fi
exit 0
