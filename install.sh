#!/usr/bin/env bash
# Public bootstrap for the private, loopback-only Huihui DeepSeek V4 Flash GGUF server.
set -Eeuo pipefail
IFS=$'\n\t'

readonly INSTALLER_URL="${DSV4_INSTALLER_URL:-https://raw.githubusercontent.com/ArcLensSF/deepseek-v4-codex-installer/main/scripts/install-huihui-gguf-remote.sh}"
temporary="$(mktemp)"
cleanup() { rm -f -- "$temporary"; }
trap cleanup EXIT

curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error "$INSTALLER_URL" -o "$temporary"
bash "$temporary"
