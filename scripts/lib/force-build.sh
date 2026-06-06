#!/usr/bin/env bash
# Force fresh download, compile, and deploy (default ON).
# Set EAI_FORCE_REBUILD=0 to allow idempotent skip paths (not recommended for validation).
set -euo pipefail

: "${EAI_FORCE_REBUILD:=1}"

eai_force_enabled() {
  [[ "${EAI_FORCE_REBUILD}" == "1" ]]
}

fresh_git_clone() {
  local url="$1" dir="$2" branch="${3:-}"
  if eai_force_enabled && [[ -d "$dir" ]]; then
    echo "[force] Removing existing clone: $dir"
    rm -rf "$dir"
  fi
  if [[ ! -d "$dir" ]]; then
    if [[ -n "$branch" ]]; then
      git clone --depth 1 --branch "$branch" "$url" "$dir"
    else
      git clone "$url" "$dir"
    fi
  elif eai_force_enabled; then
    echo "[force] Resetting clone: $dir"
    git -C "$dir" fetch --all --tags
    git -C "$dir" reset --hard HEAD
    git -C "$dir" clean -fdx
  fi
}

# Keep an existing local clone (e.g. gfx1151 feature branch) instead of deleting it.
ensure_git_repo() {
  local url="$1" dir="$2" branch="${3:-}"
  if [[ -d "$dir/.git" ]]; then
    echo "[preserve] Using existing repo: $dir (branch: $(git -C "$dir" branch --show-current 2>/dev/null || echo unknown))"
    git -C "$dir" fetch --all --tags 2>/dev/null || true
    if [[ -n "$branch" ]]; then
      git -C "$dir" checkout "$branch" 2>/dev/null || git -C "$dir" checkout -b "$branch"
    fi
    git -C "$dir" pull --ff-only 2>/dev/null || true
    return 0
  fi
  fresh_git_clone "$url" "$dir" "$branch"
}

force_remove_cmake_build() {
  local dir="$1"
  if eai_force_enabled && [[ -d "$dir" ]]; then
    echo "[force] Removing CMake build dir: $dir"
    rm -rf "$dir"
  fi
}

force_docker_build() {
  local tag="$1"
  shift
  if eai_force_enabled; then
    docker rmi "$tag" 2>/dev/null || true
    docker build --no-cache -t "$tag" "$@"
  else
    docker build -t "$tag" "$@"
  fi
}

force_helm_reinstall() {
  local release="$1" chart="$2" ns="$3"
  shift 3
  if eai_force_enabled; then
    helm uninstall "$release" -n "$ns" 2>/dev/null || true
    sleep 3
  fi
  helm upgrade --install "$release" "$chart" --namespace "$ns" --create-namespace "$@"
}

force_apt_reinstall() {
  local pkg="$1"
  if ! command -v sudo &>/dev/null; then
    echo "WARN: sudo required for apt reinstall of $pkg"
    return 0
  fi
  if eai_force_enabled; then
    sudo apt update
    sudo apt install -y --reinstall "$pkg" || sudo apt install -y "$pkg"
  else
    sudo apt install -y "$pkg"
  fi
}

force_go_build() {
  local out="$1"
  shift
  rm -f "$out"
  go build -o "$out" "$@"
}

force_k3s_reinstall() {
  if ! eai_force_enabled; then
    return 0
  fi
  if command -v k3s-uninstall.sh &>/dev/null; then
    echo "[force] Uninstalling existing k3s"
    sudo k3s-uninstall.sh || true
  fi
}
