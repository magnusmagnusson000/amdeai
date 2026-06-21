#!/usr/bin/env bash
# Install staged post-reboot cluster startup (replaces the lightweight user-unit installer).
#
# Usage:
#   bash scripts/install-stack-startup-service.sh
#   bash scripts/install-stack-startup-service.sh --uninstall
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-staged-startup-service.sh" "$@"
