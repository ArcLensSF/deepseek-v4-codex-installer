#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

bash -n install.sh bin/dsv4 bin/serve-vllm bin/serve-gateway
python3 -m unittest -v tests/test_contract.py
