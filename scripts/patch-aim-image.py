#!/usr/bin/env python3
"""
Patch the aim-gfx1151 image in the local registry with a fixed __main__.py.

Problem: aim-runtime/requirements.txt pins huggingface-hub==0.36.2 which
downgrades the >=1.5.0 version that transformers 5.5.4 (in vLLM) needs,
causing: ImportError: cannot import name 'is_offline_mode' from 'huggingface_hub'

Fix: Update __main__.py to inject a sitecustomize.py shim into PYTHONPATH
before os.execv() — the child vLLM process inherits PYTHONPATH and Python
runs sitecustomize.py at startup, patching is_offline_mode back in.

Usage: python3 scripts/patch-aim-image.py
"""
import hashlib
import io
import json
import os
import struct
import tarfile
import socket
import urllib.request
import urllib.error

REGISTRY = f"http://{socket.gethostname()}:32000"
IMAGE = "aim-gfx1151-qwen3-6-27b"
TAG = "0.11-therock"

# The fixed __main__.py content
MAIN_PY = b"""\
import os

# aim-runtime/requirements.txt pinned huggingface-hub==0.36.2, downgrading the
# >=1.5.0 that transformers 5.5.4 (bundled with vLLM) requires. Inject a shim
# via sitecustomize.py so the os.execv'd vLLM process gets it too.
_fix_dir = '/tmp/hf_compat'
os.makedirs(_fix_dir, exist_ok=True)
with open(os.path.join(_fix_dir, 'sitecustomize.py'), 'w') as _f:
    _f.write(
        "try:\\n"
        "    import huggingface_hub as _h\\n"
        "    if not hasattr(_h, 'is_offline_mode'):\\n"
        "        import os as _o\\n"
        "        _h.is_offline_mode = lambda: _o.environ.get('HF_HUB_OFFLINE','0')=='1'\\n"
        "except Exception:\\n"
        "    pass\\n"
    )
_pp = os.environ.get('PYTHONPATH', '')
os.environ['PYTHONPATH'] = _fix_dir + (':' + _pp if _pp else '')

from aim_runtime import AIMRuntime
from aim_runtime.config import AIMConfig
AIMRuntime(AIMConfig.from_environment()).serve()
"""

def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def create_layer_tar(path: str, content: bytes) -> bytes:
    """Create a minimal OCI layer tar containing one file."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tf:
        # Strip leading slash for tar
        name = path.lstrip('/')
        info = tarfile.TarInfo(name=name)
        info.size = len(content)
        info.mode = 0o644
        tf.addfile(info, io.BytesIO(content))
    return buf.getvalue()

def registry_req(method: str, path: str, data=None, headers=None, content_type=None):
    url = REGISTRY + path
    hdrs = headers or {}
    if content_type:
        hdrs['Content-Type'] = content_type
    req = urllib.request.Request(url, method=method, data=data, headers=hdrs)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()

def push_blob(layer_data: bytes) -> str:
    """Push a blob to the registry and return its digest."""
    digest = f"sha256:{sha256(layer_data)}"

    # Check if blob already exists
    status, _, _ = registry_req('HEAD', f"/v2/{IMAGE}/blobs/{digest}")
    if status == 200:
        print(f"  Blob already exists: {digest[:20]}...")
        return digest

    # Initiate upload
    status, hdrs, _ = registry_req('POST', f"/v2/{IMAGE}/blobs/uploads/")
    location = hdrs.get('Location', '')
    if not location:
        raise RuntimeError(f"Upload initiation failed: {status}")

    # Make location absolute
    if location.startswith('/'):
        location = REGISTRY + location

    # Append digest param
    sep = '&' if '?' in location else '?'
    location += f"{sep}digest={digest}"

    # PUT the blob
    status, _, _ = registry_req('PUT', location.replace(REGISTRY, ''),
                                  data=layer_data,
                                  content_type='application/octet-stream')
    if status not in (201, 202):
        raise RuntimeError(f"Blob upload failed: {status}")
    print(f"  Pushed blob: {digest[:20]}... ({len(layer_data)} bytes)")
    return digest

def get_manifest():
    """Fetch the current image manifest."""
    status, hdrs, body = registry_req(
        'GET', f"/v2/{IMAGE}/manifests/{TAG}",
        headers={'Accept': 'application/vnd.docker.distribution.manifest.v2+json'}
    )
    if status != 200:
        raise RuntimeError(f"Failed to get manifest: {status}")
    return json.loads(body)

def push_manifest(manifest: dict):
    """Push updated manifest."""
    data = json.dumps(manifest, indent=2).encode()
    status, _, body = registry_req(
        'PUT', f"/v2/{IMAGE}/manifests/{TAG}",
        data=data,
        content_type='application/vnd.docker.distribution.manifest.v2+json'
    )
    if status not in (200, 201):
        raise RuntimeError(f"Manifest push failed: {status} - {body[:200]}")
    print(f"  Manifest updated successfully")

def main():
    print("=== Patching aim-gfx1151 image in local registry ===")
    print()

    # Step 1: Create the new layer
    FILE_PATH = '/workspace/aim-runtime/src/aim_runtime/__main__.py'
    print(f"1. Creating patch layer for {FILE_PATH}")
    layer_tar = create_layer_tar(FILE_PATH, MAIN_PY)
    layer_digest = f"sha256:{sha256(layer_tar)}"
    print(f"   Layer digest: {layer_digest[:20]}... ({len(layer_tar)} bytes)")

    # Step 2: Push the new blob
    print("2. Pushing new layer blob to registry...")
    push_blob(layer_tar)

    # Step 3: Create config diff (we need to update the image config too)
    # Get existing manifest and config
    print("3. Fetching current manifest...")
    manifest = get_manifest()

    config_digest = manifest['config']['digest']
    status, _, config_body = registry_req('GET', f"/v2/{IMAGE}/blobs/{config_digest}")
    if status != 200:
        raise RuntimeError(f"Failed to get config: {status}")
    config = json.loads(config_body)

    # Update config history and rootfs diff_ids
    config.setdefault('history', []).append({
        'created_by': 'patch: fix huggingface_hub is_offline_mode compatibility'
    })
    config.setdefault('rootfs', {}).setdefault('diff_ids', []).append(layer_digest)

    config_data = json.dumps(config, indent=2).encode()
    new_config_digest = f"sha256:{sha256(config_data)}"

    # Push new config
    print("4. Pushing updated config...")
    push_blob(config_data)

    # Step 4: Update manifest
    print("5. Updating manifest with new layer...")
    manifest['layers'].append({
        'mediaType': 'application/vnd.docker.image.rootfs.diff.tar.gzip',
        'size': len(layer_tar),
        'digest': layer_digest,
    })
    manifest['config'] = {
        'mediaType': 'application/vnd.docker.container.image.v1+json',
        'size': len(config_data),
        'digest': new_config_digest,
    }
    push_manifest(manifest)

    print()
    print("=== Patch complete! ===")
    print()
    print("Next: re-pull in containerd (only the tiny new layer will download):")
    print(f"  sudo ctr -n k8s.io --address /run/k3s/containerd/containerd.sock \\")
    print(f"    images pull --plain-http {REGISTRY.replace('http://', '')}/{IMAGE}:{TAG}")

if __name__ == '__main__':
    main()
