#!/usr/bin/env bash
# Install cmake + ninja to ~/.local without sudo
set -euo pipefail
LOCAL="${HOME}/.local"
mkdir -p "$LOCAL/bin"

if ! command -v cmake &>/dev/null; then
  CMAKE_VER=3.29.6
  echo "Installing CMake ${CMAKE_VER} to ${LOCAL}"
  curl -fsSL "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VER}/cmake-${CMAKE_VER}-linux-x86_64.tar.gz" \
    | tar -xz -C "$LOCAL" --strip-components=1
fi

if ! command -v ninja &>/dev/null; then
  NINJA_VER=1.12.1
  echo "Installing ninja ${NINJA_VER} to ${LOCAL}/bin"
  curl -fsSL "https://github.com/ninja-build/ninja/releases/download/v${NINJA_VER}/ninja-linux.zip" \
    -o /tmp/ninja-linux.zip
  unzip -qo /tmp/ninja-linux.zip -d "$LOCAL/bin"
  chmod +x "$LOCAL/bin/ninja"
fi

export PATH="${LOCAL}/bin:${PATH}"
echo "cmake: $(cmake --version | head -1)"
echo "ninja: $(ninja --version)"
