#!/usr/bin/env bash
# Snapshot graphify batch progress for monitoring loops.
set -euo pipefail

LOG="${HOME}/.cache/amdeai/graphify-logs/master.log"
REPOS=(
  amdeai aim-engine cert-manager
  ROCm-Device-Libs rocminfo rocm_smi_lib HIP ROCm
  k8s-device-plugin longhorn ROCR-Runtime kaiwo clr k3s metallb
  kuberay gateway-api kueue kserve llama.cpp rocm-systems llvm-project cluster-forge
)

done=0
for name in "${REPOS[@]}"; do
  case "$name" in
    amdeai) path="/home/magnus/projects/amdeai" ;;
    ROCm-Device-Libs|rocminfo|rocm_smi_lib|HIP|ROCm|ROCR-Runtime|clr|rocm-systems|llvm-project)
      path="${HOME}/eai-build/rocm/${name}" ;;
    *) path="${HOME}/eai-build/${name}" ;;
  esac
  [[ -f "$path/graphify-out/graph.json" ]] && ((done++)) || true
done

current="$(grep -E '^=== \[' "$LOG" 2>/dev/null | tail -1 | sed -E 's/^=== \[([^]]+)\].*/\1/')"
last_chunk="$(grep -oE 'chunk [0-9]+/227 done' "$LOG" 2>/dev/null | tail -1 || true)"
cache_count=""
if [[ -n "$current" && "$current" != "skip" ]]; then
  case "$current" in
    amdeai) repo_path="/home/magnus/projects/amdeai" ;;
    ROCm-Device-Libs|rocminfo|rocm_smi_lib|HIP|ROCm|ROCR-Runtime|clr|rocm-systems|llvm-project)
      repo_path="${HOME}/eai-build/rocm/${current}" ;;
    *) repo_path="${HOME}/eai-build/${current}" ;;
  esac
  if [[ -d "$repo_path/graphify-out/cache" ]]; then
    cache_count="$(find "$repo_path/graphify-out/cache" -type f 2>/dev/null | wc -l | tr -d ' ')"
  fi
fi

running="no"
pgrep -f 'graphify extract.*--backend=ollama' >/dev/null 2>&1 && running="yes"

gpu_line="$(ollama ps 2>/dev/null | awk 'NR==2 {print $0}' || true)"
recent="$(tail -3 "$LOG" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"

printf 'repos_done=%s/%s current=%s last_chunk=%s cache_files=%s running=%s\n' \
  "$done" "${#REPOS[@]}" "${current:-unknown}" "${last_chunk:-none}" "${cache_count:-n/a}" "$running"
printf 'ollama=%s\n' "${gpu_line:-not loaded}"
printf 'recent=%s\n' "$recent"
