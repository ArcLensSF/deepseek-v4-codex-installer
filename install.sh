#!/usr/bin/env bash
# Public installer for a private loopback-only DeepSeek V4 + Codex CLI gateway.
# This file is intentionally self-contained for `curl ... | bash` use.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly INSTALLER_VERSION="1.1.0"
readonly MODEL_ID="amesianx/DeepSeek-V4-Flash-DSpark-Abliterated"
readonly MODEL_ALIAS="dsv4-abliterated"
readonly REQUIRED_FREE_GB="${DSV4_MIN_FREE_GB:-250}"
readonly VLLM_SPEC="${DSV4_VLLM_SPEC:-vllm>=0.27.1,<0.28.0}"
readonly LITELLM_SPEC="${DSV4_LITELLM_SPEC:-litellm[proxy]>=1.80.0,<2}"
readonly HF_SPEC="${DSV4_HF_SPEC:-huggingface_hub[hf_xet]>=0.34.0,<2}"

INSTALL_STARTED="$(date +%s)"
INSTALL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
INSTALL_HOME="$(getent passwd "$INSTALL_USER" 2>/dev/null | cut -d: -f6 || true)"
INSTALL_HOME="${INSTALL_HOME:-$HOME}"
DSV4_ROOT="${DSV4_ROOT:-}"
DSV4_VLLM_HOST="${DSV4_VLLM_HOST:-127.0.0.1}"
DSV4_GATEWAY_HOST="${DSV4_GATEWAY_HOST:-127.0.0.1}"
DSV4_MAX_MODEL_LEN="${DSV4_MAX_MODEL_LEN:-524288}"
DSV4_GPU_MEMORY_UTILIZATION="${DSV4_GPU_MEMORY_UTILIZATION:-0.92}"
DEPS_SECONDS=0
DOWNLOAD_SECONDS=0
RUNTIME_SECONDS=0
MODEL_LOAD_SECONDS=0
JIT_SECONDS=0

log() { printf '[dsv4 %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '[dsv4] ERROR: %s\n' "$*" >&2; exit 1; }
on_error() {
  local code=$?
  printf '[dsv4] ERROR: failed at line %s (exit %s). Re-run after fixing the issue; caches and Xet downloads are resumed.\n' "$1" "$code" >&2
  exit "$code"
}
trap 'on_error $LINENO' ERR

run_root() {
  if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}
run_as_install_user() {
  if [[ "$EUID" -eq 0 && "$INSTALL_USER" != root ]]; then sudo -H -u "$INSTALL_USER" "$@"; else "$@"; fi
}
is_loopback() { [[ "$1" == "127.0.0.1" || "$1" == "::1" || "$1" == "localhost" ]]; }

validate_inputs() {
  [[ "$(uname -s)" == Linux ]] || die "Linux is required."
  [[ "$DSV4_VLLM_HOST" == "127.0.0.1" ]] || die "vLLM is fixed to 127.0.0.1 so its unauthenticated backend can never be exposed."
  if ! is_loopback "$DSV4_GATEWAY_HOST"; then
    [[ "${DSV4_ALLOW_PUBLIC_GATEWAY:-0}" == 1 ]] || die "Refusing a public gateway. Set DSV4_ALLOW_PUBLIC_GATEWAY=1 only for a deliberate, separately firewalled deployment."
    log "WARNING: gateway will be exposed on $DSV4_GATEWAY_HOST. You are responsible for TLS and firewalling."
  fi
  [[ "$DSV4_MAX_MODEL_LEN" =~ ^[0-9]+$ ]] || die "DSV4_MAX_MODEL_LEN must be an integer."
  [[ "$REQUIRED_FREE_GB" =~ ^[0-9]+$ ]] || die "DSV4_MIN_FREE_GB must be an integer."
}

install_os_dependencies() {
  local started
  started="$(date +%s)"
  [[ -r /etc/os-release ]] || die "Unsupported Linux distribution: missing /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  log "Installing Linux dependencies."
  case "${ID:-}" in
    ubuntu|debian)
      run_root env DEBIAN_FRONTEND=noninteractive apt-get update -y
      run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git jq lsof procps psmisc pciutils numactl build-essential pkg-config libnuma1 openssl
      ;;
    rhel|rocky|almalinux|fedora)
      local pm=dnf
      command -v dnf >/dev/null 2>&1 || pm=yum
      run_root "$pm" install -y ca-certificates curl git jq lsof procps-ng psmisc pciutils numactl gcc gcc-c++ make pkgconf-pkg-config numactl-libs openssl
      ;;
    *) die "Unsupported distribution '${ID:-unknown}'. Supported: Ubuntu/Debian, RHEL/Rocky/Alma/Fedora." ;;
  esac
  DEPS_SECONDS="$(( $(date +%s) - started ))"
  log "Dependencies installed in ${DEPS_SECONDS}s."
}

verify_host_and_detect_gpus() {
  command -v systemctl >/dev/null 2>&1 || die "systemd is required for background services."
  systemctl --version >/dev/null 2>&1 || die "systemd is not active."
  command -v nvidia-smi >/dev/null 2>&1 || die "A GPU image with working NVIDIA drivers is required; nvidia-smi was not found."
  local line index name memory
  local -a gpus=()
  mapfile -t gpus < <(nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader,nounits)
  GPU_COUNT="${#gpus[@]}"
  (( GPU_COUNT > 0 )) || die "No NVIDIA GPUs detected."
  log "Detected ${GPU_COUNT} GPU(s):"
  for line in "${gpus[@]}"; do
    IFS=',' read -r index name memory <<<"$line"
    name="$(xargs <<<"$name")"; memory="$(xargs <<<"$memory")"
    printf '  GPU %s: %s (%s MiB)\n' "$index" "$name" "$memory"
    if [[ "${name,,}" != *"rtx pro 6000 blackwell"* ]] || (( memory < 90000 )); then
      [[ "${DSV4_ALLOW_UNSUPPORTED_GPU:-0}" == 1 ]] || die "Unsupported GPU '$name' (${memory} MiB). Target hardware is RTX PRO 6000 Blackwell 96 GB; use DSV4_ALLOW_UNSUPPORTED_GPU=1 only after validation."
    fi
  done
  if [[ "$GPU_COUNT" != 2 && "$GPU_COUNT" != 4 && "${DSV4_ALLOW_UNSUPPORTED_GPU:-0}" != 1 ]]; then
    die "Expected 2 or 4 GPUs; found $GPU_COUNT. Set DSV4_ALLOW_UNSUPPORTED_GPU=1 only for a validated alternative layout."
  fi
  log "Using tensor parallelism TP=$GPU_COUNT."
}

largest_local_mount() {
  local target type avail best_target="" best_avail=0
  while read -r target type avail; do
    [[ -n "$target" && "$avail" =~ ^[0-9]+$ ]] || continue
    case "$type" in tmpfs|devtmpfs|squashfs|overlay|proc|sysfs|cgroup*|nfs*|cifs|smb*) continue;; esac
    [[ "$target" != /boot && "$target" != /boot/efi ]] || continue
    if (( avail > best_avail )); then best_target="$target"; best_avail="$avail"; fi
  done < <(findmnt -rnb -o TARGET,FSTYPE,AVAIL 2>/dev/null || true)
  [[ -n "$best_target" ]] || die "Could not find a suitable local mounted disk. Set DSV4_ROOT explicitly."
  printf '%s\n' "$best_target"
}

prepare_storage() {
  local mount free_bytes minimum_bytes group
  if [[ -z "$DSV4_ROOT" ]]; then
    mount="$(largest_local_mount)"
    [[ "$mount" == / ]] && DSV4_ROOT=/opt/dsv4 || DSV4_ROOT="${mount%/}/dsv4"
  fi
  [[ "$DSV4_ROOT" == /* && "$DSV4_ROOT" != / && "$DSV4_ROOT" != *$'\n'* ]] || die "DSV4_ROOT must be a safe, absolute non-root path."
  group="$(id -gn "$INSTALL_USER")"
  run_root mkdir -p "$DSV4_ROOT"
  run_root chown "$INSTALL_USER:$group" "$DSV4_ROOT"
  free_bytes="$(df -PB1 "$DSV4_ROOT" | awk 'NR==2 {print $4}')"
  minimum_bytes="$(( REQUIRED_FREE_GB * 1000 * 1000 * 1000 ))"
  [[ "$free_bytes" =~ ^[0-9]+$ ]] && (( free_bytes >= minimum_bytes )) || die "Need ${REQUIRED_FREE_GB} GB free at $DSV4_ROOT; select a larger local disk with DSV4_ROOT."
  DSV4_CACHE="$DSV4_ROOT/cache"
  DSV4_HF_HOME="$DSV4_CACHE/huggingface"
  DSV4_HF_HUB_CACHE="$DSV4_HF_HOME/hub"
  DSV4_UV_CACHE="$DSV4_CACHE/uv"
  DSV4_TORCH_CACHE="$DSV4_CACHE/torch"
  DSV4_STATE="$DSV4_ROOT/state"
  DSV4_CONFIG="$DSV4_ROOT/config"
  DSV4_BIN="$DSV4_ROOT/bin"
  run_as_install_user mkdir -p "$DSV4_HF_HUB_CACHE" "$DSV4_UV_CACHE" "$DSV4_TORCH_CACHE" "$DSV4_STATE" "$DSV4_CONFIG" "$DSV4_BIN"
  log "Using $DSV4_ROOT ($(( free_bytes / 1000 / 1000 / 1000 )) GB free)."
}

install_uv_and_python() {
  local installer
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
  elif [[ -x "$INSTALL_HOME/.local/bin/uv" ]]; then
    UV_BIN="$INSTALL_HOME/.local/bin/uv"
  else
    log "Installing uv."
    installer="$(mktemp)"
    curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error https://astral.sh/uv/install.sh -o "$installer"
    run_as_install_user sh "$installer" --no-modify-path
    rm -f "$installer"
    UV_BIN="$INSTALL_HOME/.local/bin/uv"
  fi
  [[ -x "$UV_BIN" ]] || die "uv installation failed."
  run_as_install_user env UV_CACHE_DIR="$DSV4_UV_CACHE" "$UV_BIN" python install 3.12
  if [[ ! -x "$DSV4_ROOT/venv/bin/python" ]]; then
    run_as_install_user env UV_CACHE_DIR="$DSV4_UV_CACHE" "$UV_BIN" venv --python 3.12 "$DSV4_ROOT/venv"
  fi
  VENV_PYTHON="$DSV4_ROOT/venv/bin/python"
}

install_runtime_stack() {
  local marker="$DSV4_STATE/runtime-stack-${INSTALLER_VERSION}"
  cat > "$DSV4_CONFIG/requirements.txt" <<EOF
$VLLM_SPEC
$LITELLM_SPEC
$HF_SPEC
EOF
  if [[ -f "$marker" ]] && "$VENV_PYTHON" -c 'import vllm,litellm,huggingface_hub,hf_xet' >/dev/null 2>&1; then
    log "Reusing the Python 3.12 vLLM/LiteLLM/Hugging Face runtime."
    return
  fi
  log "Installing the vLLM Blackwell serving stack, LiteLLM, and Hugging Face/Xet."
  run_as_install_user env UV_CACHE_DIR="$DSV4_UV_CACHE" "$UV_BIN" pip install --python "$VENV_PYTHON" --upgrade -r "$DSV4_CONFIG/requirements.txt"
  run_as_install_user "$VENV_PYTHON" - <<'PY'
import torch
assert torch.cuda.is_available(), "PyTorch cannot access CUDA"
print(f"CUDA runtime {torch.version.cuda}; {torch.cuda.device_count()} GPU(s) visible")
PY
  run_as_install_user touch "$marker"
}

download_model() {
  local started tmp model_path recorded_model
  recorded_model="$(<"$DSV4_STATE/model-id" 2>/dev/null || true)"
  if [[ -f "$DSV4_STATE/model-path" && "$recorded_model" == "$MODEL_ID" ]]; then
    model_path="$(<"$DSV4_STATE/model-path")"
    if [[ "$model_path" == "$DSV4_HF_HUB_CACHE"/* && -f "$model_path/config.json" ]]; then
      MODEL_PATH="$model_path"; DOWNLOAD_SECONDS=0
      log "Reusing model snapshot: $MODEL_PATH"
      return
    fi
  fi
  if [[ -n "$recorded_model" && "$recorded_model" != "$MODEL_ID" ]]; then
    log "Cached state targets '$recorded_model'; downloading the requested checkpoint instead."
  fi
  started="$(date +%s)"; tmp="$DSV4_STATE/model-path.downloading"
  rm -f "$tmp"
  log "Downloading $MODEL_ID through Hugging Face Xet (resumable, content-addressed, no duplicate model copy)."
  local -a hf_env=(env "HF_HOME=$DSV4_HF_HOME" "HF_HUB_CACHE=$DSV4_HF_HUB_CACHE" "HF_XET_HIGH_PERFORMANCE=1")
  [[ -n "${HF_TOKEN:-}" ]] && hf_env+=("HF_TOKEN=$HF_TOKEN")
  run_as_install_user "${hf_env[@]}" "$VENV_PYTHON" - "$MODEL_ID" "$DSV4_HF_HUB_CACHE" > "$tmp" <<'PY'
import sys
from huggingface_hub import snapshot_download
print(snapshot_download(repo_id=sys.argv[1], repo_type="model", cache_dir=sys.argv[2]))
PY
  model_path="$(tail -n1 "$tmp")"
  [[ "$model_path" == "$DSV4_HF_HUB_CACHE"/* && -f "$model_path/config.json" ]] || die "The Hugging Face download did not produce a valid model snapshot."
  printf '%s\n' "$model_path" > "$DSV4_STATE/model-path"
  printf '%s\n' "$MODEL_ID" > "$DSV4_STATE/model-id"
  rm -f "$tmp"; MODEL_PATH="$model_path"
  DOWNLOAD_SECONDS="$(( $(date +%s) - started ))"
  log "Model download completed in ${DOWNLOAD_SECONDS}s."
}

write_config_and_launchers() {
  local key creds_tmp
  key="$(run_root awk -F= '/^DSV4_API_KEY=/{print $2; exit}' /etc/dsv4/credentials.env 2>/dev/null || true)"
  if [[ ! "$key" =~ ^sk-dsv4-[A-Fa-f0-9]{64}$ ]]; then
    key="sk-dsv4-$(openssl rand -hex 32)"; log "Generated a new 256-bit gateway key."
  else
    log "Reusing the existing gateway API key."
  fi
  cat > "$DSV4_CONFIG/runtime.env" <<EOF
DSV4_ROOT=$(printf '%q' "$DSV4_ROOT")
MODEL_PATH=$(printf '%q' "$MODEL_PATH")
MODEL_ALIAS=$(printf '%q' "$MODEL_ALIAS")
GPU_COUNT=$(printf '%q' "$GPU_COUNT")
DSV4_VLLM_HOST=$(printf '%q' "$DSV4_VLLM_HOST")
DSV4_GATEWAY_HOST=$(printf '%q' "$DSV4_GATEWAY_HOST")
DSV4_MAX_MODEL_LEN=$(printf '%q' "$DSV4_MAX_MODEL_LEN")
DSV4_GPU_MEMORY_UTILIZATION=$(printf '%q' "$DSV4_GPU_MEMORY_UTILIZATION")
HF_HOME=$(printf '%q' "$DSV4_HF_HOME")
HF_HUB_CACHE=$(printf '%q' "$DSV4_HF_HUB_CACHE")
TORCHINDUCTOR_CACHE_DIR=$(printf '%q' "$DSV4_TORCH_CACHE/inductor")
TRITON_CACHE_DIR=$(printf '%q' "$DSV4_TORCH_CACHE/triton")
EOF
  chmod 600 "$DSV4_CONFIG/runtime.env"
  cat > "$DSV4_CONFIG/litellm.yaml" <<'EOF'
model_list:
  - model_name: dsv4-abliterated
    litellm_params:
      model: openai/dsv4-abliterated
      api_base: http://127.0.0.1:8000/v1
      api_key: dsv4-loopback-backend
litellm_settings:
  master_key: os.environ/DSV4_API_KEY
  drop_params: true
general_settings:
  disable_spend_logs: true
EOF
  chmod 600 "$DSV4_CONFIG/litellm.yaml"
  creds_tmp="$(mktemp)"; printf 'DSV4_API_KEY=%s\n' "$key" > "$creds_tmp"
  run_root install -d -m 700 /etc/dsv4
  run_root install -o root -g root -m 600 "$creds_tmp" /etc/dsv4/credentials.env
  rm -f "$creds_tmp"
  cat > "$DSV4_BIN/serve-vllm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/runtime.env"
export HF_XET_HIGH_PERFORMANCE=1 HF_HOME HF_HUB_CACHE TORCHINDUCTOR_CACHE_DIR TRITON_CACHE_DIR
# The DSpark checkpoint owns its native FP8 decoder and FP4 expert formats.
# Do not add a vLLM weight-quantization override here.
export VLLM_USE_DEEP_GEMM=1 VLLM_MOE_USE_DEEP_GEMM=1 VLLM_DEEPEPLL_NVFP4_DISPATCH=1 VLLM_USE_FLASHINFER_MOE_FP4=1
exec "$DSV4_ROOT/venv/bin/vllm" serve "$MODEL_PATH" \
  --host "$DSV4_VLLM_HOST" --port 8000 --served-model-name "$MODEL_ALIAS" \
  --tensor-parallel-size "$GPU_COUNT" --enable-expert-parallel \
  --gpu-memory-utilization "$DSV4_GPU_MEMORY_UTILIZATION" --max-model-len "$DSV4_MAX_MODEL_LEN" \
  --kv-cache-dtype fp8 --block-size 256 --tokenizer-mode deepseek_v4 \
  --tool-call-parser deepseek_v4 --enable-auto-tool-choice --reasoning-parser deepseek_v4 \
  --speculative-config '{"method":"dspark","num_speculative_tokens":5,"draft_sample_method":"probabilistic"}' \
  --compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY"}'
EOF
  cat > "$DSV4_BIN/serve-gateway" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/runtime.env"
export LITELLM_LOG=ERROR NO_PROXY="127.0.0.1,localhost,::1"
exec "$DSV4_ROOT/venv/bin/litellm" --config "$DSV4_ROOT/config/litellm.yaml" --host "$DSV4_GATEWAY_HOST" --port 4000
EOF
  chmod 755 "$DSV4_BIN/serve-vllm" "$DSV4_BIN/serve-gateway"
  cat > "$DSV4_CONFIG/dsv4.conf" <<EOF
DSV4_ROOT=$(printf '%q' "$DSV4_ROOT")
DSV4_USER=$(printf '%q' "$INSTALL_USER")
DSV4_UV_BIN=$(printf '%q' "$UV_BIN")
DSV4_UV_CACHE=$(printf '%q' "$DSV4_UV_CACHE")
DSV4_MODEL_ALIAS=$(printf '%q' "$MODEL_ALIAS")
DSV4_GATEWAY_URL=$(printf '%q' "http://$DSV4_GATEWAY_HOST:4000")
DSV4_VLLM_SPEC=$(printf '%q' "$VLLM_SPEC")
DSV4_LITELLM_SPEC=$(printf '%q' "$LITELLM_SPEC")
DSV4_HF_SPEC=$(printf '%q' "$HF_SPEC")
EOF
  run_root install -m 644 "$DSV4_CONFIG/dsv4.conf" /etc/dsv4/dsv4.conf
}

install_services() {
  local tmp group
  tmp="$(mktemp)"; group="$(id -gn "$INSTALL_USER")"
  cat > "$tmp" <<EOF
[Unit]
Description=DeepSeek V4 vLLM backend (loopback only)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=$INSTALL_USER
Group=$group
WorkingDirectory=$DSV4_ROOT
Environment=HOME=$INSTALL_HOME
Environment=HF_XET_HIGH_PERFORMANCE=1
ExecStart=$DSV4_BIN/serve-vllm
Restart=on-failure
RestartSec=5
TimeoutStartSec=infinity
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
  run_root install -m 644 "$tmp" /etc/systemd/system/dsv4-vllm.service
  cat > "$tmp" <<EOF
[Unit]
Description=Authenticated OpenAI Responses gateway for DeepSeek V4
After=network-online.target dsv4-vllm.service
Wants=network-online.target
[Service]
Type=simple
User=$INSTALL_USER
Group=$group
WorkingDirectory=$DSV4_ROOT
Environment=HOME=$INSTALL_HOME
EnvironmentFile=/etc/dsv4/credentials.env
ExecStart=$DSV4_BIN/serve-gateway
Restart=on-failure
RestartSec=3
TimeoutStartSec=120
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
  run_root install -m 644 "$tmp" /etc/systemd/system/dsv4-gateway.service
  rm -f "$tmp"
  run_root systemctl daemon-reload
  run_root systemctl enable dsv4-vllm.service dsv4-gateway.service >/dev/null
}

install_cli() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
readonly CONF=/etc/dsv4/dsv4.conf
readonly CREDS=/etc/dsv4/credentials.env
[[ -r "$CONF" ]] || { echo "dsv4: not installed" >&2; exit 1; }
source "$CONF"
root() { if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
as_service_user() { if [[ "$EUID" -eq 0 && "$DSV4_USER" != root ]]; then sudo -H -u "$DSV4_USER" "$@"; else "$@"; fi; }
key() { root awk -F= '/^DSV4_API_KEY=/{print $2; exit}' "$CREDS"; }
usage() { cat <<'USAGE'
Usage: dsv4 {start|stop|restart|status|logs [--follow]|credentials|update|uninstall --yes}
USAGE
}
case "${1:-}" in
  start|stop|restart) root systemctl "$1" dsv4-vllm.service dsv4-gateway.service ;;
  status)
    printf 'vLLM:    '; root systemctl is-active dsv4-vllm.service || true
    printf 'gateway: '; root systemctl is-active dsv4-gateway.service || true
    curl --fail --silent --max-time 3 http://127.0.0.1:8000/health >/dev/null && echo 'vLLM health: OK' || echo 'vLLM health: unavailable'
    curl --fail --silent --max-time 3 -H "Authorization: Bearer $(key)" "$DSV4_GATEWAY_URL/v1/models" >/dev/null && echo 'gateway auth: OK' || echo 'gateway auth: unavailable'
    ;;
  logs)
    if [[ "${2:-}" == --follow || "${2:-}" == -f ]]; then root journalctl -fu dsv4-vllm.service -u dsv4-gateway.service; else root journalctl --no-pager -n "${DSV4_LOG_LINES:-200}" -u dsv4-vllm.service -u dsv4-gateway.service; fi
    ;;
  credentials) printf 'API KEY:\n%s\n\nMODEL:\n%s\n\nLOCAL GATEWAY:\n%s\n' "$(key)" "$DSV4_MODEL_ALIAS" "$DSV4_GATEWAY_URL" ;;
  update)
    echo 'Updating Python serving packages; model cache and API key are retained.'
    as_service_user env UV_CACHE_DIR="$DSV4_UV_CACHE" "$DSV4_UV_BIN" pip install --python "$DSV4_ROOT/venv/bin/python" --upgrade "$DSV4_VLLM_SPEC" "$DSV4_LITELLM_SPEC" "$DSV4_HF_SPEC"
    root systemctl restart dsv4-vllm.service dsv4-gateway.service
    ;;
  uninstall)
    [[ "${2:-}" == --yes ]] || { echo "dsv4: this permanently removes $DSV4_ROOT and the model. Re-run: dsv4 uninstall --yes" >&2; exit 1; }
    [[ "$DSV4_ROOT" == /* && "$DSV4_ROOT" != / && "$DSV4_ROOT" != /opt ]] || { echo 'dsv4: refusing unsafe removal target' >&2; exit 1; }
    root systemctl disable --now dsv4-gateway.service dsv4-vllm.service || true
    root rm -f /etc/systemd/system/dsv4-vllm.service /etc/systemd/system/dsv4-gateway.service /etc/dsv4/dsv4.conf /etc/dsv4/credentials.env
    root systemctl daemon-reload
    root rm -rf -- "$DSV4_ROOT"
    root rm -f /usr/local/bin/dsv4
    echo 'DeepSeek V4 services, credentials, and cached model removed.'
    ;;
  -h|--help|help|'') usage ;;
  *) echo "dsv4: unknown command '$1'" >&2; usage; exit 1 ;;
esac
EOF
  run_root install -m 755 "$tmp" /usr/local/bin/dsv4
  rm -f "$tmp"
}

wait_for() {
  local url="$1" label="$2" timeout="$3" header="${4:-}" started now
  started="$(date +%s)"
  while true; do
    if [[ -n "$header" ]]; then curl --fail --silent --max-time 5 -H "$header" "$url" >/dev/null 2>&1 && return; else curl --fail --silent --max-time 5 "$url" >/dev/null 2>&1 && return; fi
    now="$(date +%s)"
    (( now - started < timeout )) || { run_root journalctl --no-pager -n 80 -u dsv4-vllm.service -u dsv4-gateway.service >&2 || true; die "Timed out waiting for $label; inspect with dsv4 logs."; }
    (( (now - started) % 30 == 0 )) && log "Waiting for $label ($((now-started))s elapsed)..."
    sleep 2
  done
}

start_and_verify() {
  local started warmup_started key
  started="$(date +%s)"
  log "Starting vLLM in the background. First startup compiles Blackwell kernels."
  run_root systemctl restart dsv4-vllm.service
  wait_for http://127.0.0.1:8000/health 'vLLM model API' 3600
  MODEL_LOAD_SECONDS="$(( $(date +%s) - started ))"
  warmup_started="$(date +%s)"
  log "Running one local warm-up request for JIT/kernel initialization."
  curl --fail --silent --max-time 900 -H 'Content-Type: application/json' -d "{\"model\":\"$MODEL_ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK.\"}],\"max_tokens\":1,\"temperature\":0}" http://127.0.0.1:8000/v1/chat/completions >/dev/null
  JIT_SECONDS="$(( $(date +%s) - warmup_started ))"
  run_root systemctl restart dsv4-gateway.service
  key="$(run_root awk -F= '/^DSV4_API_KEY=/{print $2; exit}' /etc/dsv4/credentials.env)"
  wait_for http://127.0.0.1:4000/v1/models 'authenticated Codex gateway' 180 "Authorization: Bearer $key"
  # Codex speaks Responses API, so verify that actual protocol rather than merely the model list.
  curl --fail --silent --max-time 900 -H "Authorization: Bearer $key" -H 'Content-Type: application/json' -d "{\"model\":\"$MODEL_ALIAS\",\"input\":\"Reply with OK.\",\"max_output_tokens\":1}" http://127.0.0.1:4000/v1/responses >/dev/null
  RUNTIME_SECONDS="$(( $(date +%s) - started ))"
  printf 'dependency_install_seconds=%s\nmodel_download_seconds=%s\nruntime_initialization_seconds=%s\nmodel_load_to_health_seconds=%s\nfirst_request_jit_kernel_seconds=%s\n' "$DEPS_SECONDS" "$DOWNLOAD_SECONDS" "$RUNTIME_SECONDS" "$MODEL_LOAD_SECONDS" "$JIT_SECONDS" > "$DSV4_STATE/timings.env"
}

print_ready() {
  local key total
  key="$(run_root awk -F= '/^DSV4_API_KEY=/{print $2; exit}' /etc/dsv4/credentials.env)"
  total="$(( $(date +%s) - INSTALL_STARTED ))"
  cat <<EOF

Timing summary:
  dependency installation: ${DEPS_SECONDS}s
  model download:          ${DOWNLOAD_SECONDS}s (0 means cache reused)
  runtime initialization:  ${RUNTIME_SECONDS}s
  model load to health:    ${MODEL_LOAD_SECONDS}s
  JIT/kernel warm-up:      ${JIT_SECONDS}s
  total until API ready:   ${total}s

========================================
DEEPSEEK V4 READY
========================================

API KEY:
$key

MODEL:
$MODEL_ALIAS

LOCAL GATEWAY:
http://127.0.0.1:4000

FROM YOUR LAPTOP:

ssh -L 4000:127.0.0.1:4000 USER@SERVER_IP

Then create ~/.codex/dsv4.config.toml:

model = "$MODEL_ALIAS"
model_provider = "dsv4"
model_context_window = $DSV4_MAX_MODEL_LEN
model_supports_reasoning_summaries = false

[model_providers.dsv4]
name = "Private DeepSeek V4"
base_url = "http://127.0.0.1:4000/v1"
env_key = "DSV4_API_KEY"
wire_api = "responses"
request_max_retries = 2
stream_max_retries = 2

Then:

export DSV4_API_KEY="$key"
codex --profile dsv4
========================================
EOF
}

main() {
  log "DeepSeek V4 installer ${INSTALLER_VERSION} starting."
  validate_inputs
  [[ "$EUID" -eq 0 ]] || { command -v sudo >/dev/null 2>&1 || die "sudo is required."; sudo -v; }
  install_os_dependencies
  verify_host_and_detect_gpus
  prepare_storage
  install_uv_and_python
  install_runtime_stack
  download_model
  write_config_and_launchers
  install_services
  install_cli
  start_and_verify
  print_ready
}
main "$@"
