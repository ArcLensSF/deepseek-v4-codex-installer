#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

bash -n install.sh scripts/install-huihui-gguf-remote.sh
python3 -m unittest -v tests/test_contract.py
