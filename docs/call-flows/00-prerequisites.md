# Call flow: prerequisites (build toolchain)

**Not in runtime inference path.**

## Purpose

Downloads and installs tools used **only at build/deploy time**:

- Go → compile cluster-forge, kaiwo, aim-engine helpers
- CMake/ninja → llama.cpp Vulkan build
- Helm/kubectl → deploy charts
- Docker → build device-plugin and operator images
- Python venv (`/home/magnus/projects/venvs/amd`) → pytest + Playwright validation

## “Flow” during build

Developer runs `scripts/00-prerequisites.sh` → packages land on disk → subsequent scripts invoke compilers.

No chat prompt touches these binaries at inference time.
