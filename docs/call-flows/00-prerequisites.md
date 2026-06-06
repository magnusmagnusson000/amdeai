# Call flow: prerequisites (build toolchain)

**Script:** `scripts/00-prerequisites.sh`  
**Not in runtime inference path.**

## Purpose

Installs tools used at **build and deploy time**:

| Tool | Used by |
|------|---------|
| Go | cluster-forge, kaiwo, aim-engine |
| CMake / ninja | llama.cpp (Vulkan + HIP) |
| Helm / kubectl | All Kubernetes layers |
| Docker | k8s-device-plugin, kaiwo operator images |
| Python venv | pytest, Playwright |

**Venv:** `/home/magnus/projects/venvs/amd`

```bash
source /home/magnus/projects/venvs/amd/bin/activate
pip install -r tests/requirements.txt
playwright install chromium
```

## Study tree sync

Refresh all upstream repos under `~/eai-build/`:

```bash
bash scripts/sync-eai-build.sh
# or initial clone:
bash scripts/fetch-study-sources.sh
```

## Relation to call flows

Prerequisites enable the numbered install pipeline (`00` … `07`). No chat token traverses these binaries at inference time.

See [README.md](../../README.md) for the full system install guide.
