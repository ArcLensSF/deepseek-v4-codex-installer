#!/usr/bin/env bash
# Installs the Huihui DeepSeek V4 Flash GGUF serving stack on a mounted
# persistent volume. Intended to be copied to and run as root on the GPU host.
set -Eeuo pipefail

choose_volume() {
  local target type avail best_target='' best_avail=0
  if [[ -n "${DSV4_VOLUME:-}" ]]; then
    printf '%s\n' "$DSV4_VOLUME"
    return
  fi
  # Prefer the conventional attached persistent volume when it is actually a mount.
  if [[ "$(findmnt -rn -T /mnt/dsv4 -o TARGET 2>/dev/null || true)" == /mnt/dsv4 ]]; then
    printf '%s\n' /mnt/dsv4
    return
  fi
  while read -r target type; do
    case "$type" in tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|cgroup*|nfs*|cifs|smb*) continue ;; esac
    [[ "$target" != /boot && "$target" != /boot/efi ]] || continue
    avail="$(df -PB1 "$target" 2>/dev/null | awk 'NR == 2 {print $4}')"
    [[ "$avail" =~ ^[0-9]+$ ]] || continue
    if (( avail > best_avail )); then best_target="$target"; best_avail="$avail"; fi
  done < <(findmnt -rn -o TARGET,FSTYPE 2>/dev/null || true)
  [[ -n "$best_target" ]] || { echo 'Could not identify a local writable volume.' >&2; exit 1; }
  printf '%s\n' "$best_target"
}

readonly DSV4_VOLUME="$(choose_volume)"
if [[ -z "${DSV4_ROOT:-}" ]]; then
  if [[ "$DSV4_VOLUME" == / ]]; then
    DSV4_ROOT=/opt/dsv4-huihui-gguf
  else
    DSV4_ROOT="${DSV4_VOLUME%/}/dsv4-huihui-gguf"
  fi
fi
readonly DSV4_ROOT
readonly MODEL_REPO="huihui-ai/Huihui-DeepSeek-V4-Flash-0731-abliterated-GGUF"
readonly MODEL_REVISION="a8dfba9c1e43bdf324ee2c7787ed01c70975ffb4"
readonly MODEL_FILE="DeepSeek-V4-Flash-Q4-mxfp4-0731.gguf"
readonly DRAFT_FILE="dspark-abliterated/dspark-DeepSeek-V4-Flash-0731-BF16.gguf"
readonly MODEL_ALIAS="dsv4-huihui-0731-abliterated"
readonly CUDA_IMAGE="nvidia/cuda:12.8.1-devel-ubuntu24.04"
readonly STARTED_AT="$(date +%s)"

log() { printf '[dsv4 %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
elapsed() { local seconds=$1; printf '%dm %02ds' "$((seconds / 60))" "$((seconds % 60))"; }
require_root() { [[ "$EUID" -eq 0 ]] || { echo 'Run this installer as root.' >&2; exit 1; }; }
verify_gpus() {
  local line index name memory
  command -v nvidia-smi >/dev/null 2>&1 || { echo 'A CUDA GPU image with nvidia-smi is required.' >&2; exit 1; }
  mapfile -t detected_gpus < <(nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader,nounits)
  (( ${#detected_gpus[@]} == 4 )) || { echo "This Q4 512k profile requires 4× RTX PRO 6000 Blackwell GPUs; found ${#detected_gpus[@]}." >&2; exit 1; }
  log 'Detected GPUs:'
  for line in "${detected_gpus[@]}"; do
    IFS=',' read -r index name memory <<<"$line"
    name="$(xargs <<<"$name")"; memory="$(xargs <<<"$memory")"
    printf '  GPU %s: %s (%s MiB)\n' "$index" "$name" "$memory"
    [[ "${name,,}" == *'rtx pro 6000 blackwell'* && "$memory" -ge 90000 ]] || { echo "Unsupported GPU: $name ($memory MiB)." >&2; exit 1; }
  done
}
safe_remove_old_install() {
  local old_root=/mnt/dsv4/deepseek
  [[ "$old_root" == /mnt/dsv4/deepseek ]] || { echo 'Unsafe old-install target.' >&2; exit 1; }
  [[ -e "$old_root" || -e /etc/systemd/system/dsv4-vllm.service ]] || return 0
  systemctl disable --now dsv4-gateway.service dsv4-vllm.service 2>/dev/null || true
  docker rm -f dsv4-vllm-worker 2>/dev/null || true
  systemctl stop docker.service containerd.service 2>/dev/null || true
  rm -rf -- "$old_root"
  rm -f -- /etc/systemd/system/dsv4-vllm.service /etc/systemd/system/dsv4-gateway.service
  rm -f -- /etc/dsv4/dsv4.conf /etc/dsv4/credentials.env /usr/local/bin/dsv4
  if [[ -f /etc/docker/daemon.json ]] && grep -Fq '/mnt/dsv4/deepseek' /etc/docker/daemon.json; then
    rm -f -- /etc/docker/daemon.json
  fi
  if [[ -f /etc/containerd/config.toml ]] && grep -Fq '/mnt/dsv4/deepseek' /etc/containerd/config.toml; then
    rm -f -- /etc/containerd/config.toml
  fi
  systemctl daemon-reload
}
write_file() {
  # write_file MODE DESTINATION then content on stdin
  local mode=$1 destination=$2 temporary
  temporary="$(mktemp)"
  cat >"$temporary"
  install -D -m "$mode" "$temporary" "$destination"
  rm -f -- "$temporary"
}
on_error() {
  local status=$?
  log "Installation stopped (exit ${status}). Re-run this same script to resume the model download."
  exit "$status"
}
trap on_error ERR

require_root
verify_gpus
findmnt -T "$DSV4_VOLUME" >/dev/null || { echo "$DSV4_VOLUME is not a mounted volume." >&2; exit 1; }
[[ "$DSV4_ROOT" == "$DSV4_VOLUME"/* ]] || { echo 'DSV4_ROOT must live under the mounted persistent volume.' >&2; exit 1; }

log "Purging the old vLLM installation at /mnt/dsv4/deepseek."
safe_remove_old_install
mkdir -p "$DSV4_ROOT"/{bin,build,logs,models,cache,src}
free_gib="$(df -BG --output=avail "$DSV4_VOLUME" | tail -1 | tr -dc '0-9')"
required_free_gib=190
if [[ -s "$DSV4_ROOT/models/$MODEL_FILE" && -s "$DSV4_ROOT/models/$DRAFT_FILE" ]]; then
  required_free_gib=20
fi
(( free_gib >= required_free_gib )) || { echo "Need ${required_free_gib} GiB free on $DSV4_VOLUME; found ${free_gib} GiB." >&2; exit 1; }

deps_started="$(date +%s)"
log 'Installing system dependencies and uv/Python 3.12.'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git build-essential cmake pkg-config jq >/dev/null
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o /tmp/docker-installer.sh
  sh /tmp/docker-installer.sh
  rm -f /tmp/docker-installer.sh
fi
if ! command -v uv >/dev/null 2>&1; then
  curl -fsSL https://astral.sh/uv/install.sh -o /tmp/uv-installer.sh
  env UV_INSTALL_DIR=/usr/local/bin sh /tmp/uv-installer.sh
  rm -f /tmp/uv-installer.sh
fi
export PATH="/usr/local/bin:/root/.local/bin:$PATH"
uv python install 3.12 >/dev/null
if [[ ! -x "$DSV4_ROOT/venv/bin/python" ]]; then
  uv venv --python 3.12 "$DSV4_ROOT/venv" >/dev/null
fi
uv pip install --python "$DSV4_ROOT/venv/bin/python" \
  'huggingface_hub[hf_xet]>=0.34,<2' 'litellm[proxy]>=1.80,<2' 'fastapi==0.115.12' >/dev/null
log "Dependency installation: $(elapsed "$(( $(date +%s) - deps_started ))")."

log 'Preparing Docker for the isolated CUDA build/runtime.'
systemctl enable --now docker >/dev/null
docker pull "$CUDA_IMAGE" >/dev/null

download_started="$(date +%s)"
download_pid=''
if [[ ! -s "$DSV4_ROOT/models/$MODEL_FILE" || ! -s "$DSV4_ROOT/models/$DRAFT_FILE" ]]; then
  log "Downloading only the Q4 model (156 GB) and BF16 DSpark draft (11.3 GB) to $DSV4_ROOT/models."
  (
    export HF_XET_HIGH_PERFORMANCE=1
    export HF_HOME="$DSV4_ROOT/cache/huggingface"
    if [[ -r /root/.cache/huggingface/token ]]; then
      export HF_TOKEN="$(tr -d '\\r\\n' < /root/.cache/huggingface/token)"
    fi
    "$DSV4_ROOT/venv/bin/hf" download "$MODEL_REPO" \
      "$MODEL_FILE" "$DRAFT_FILE" \
      --revision "$MODEL_REVISION" --local-dir "$DSV4_ROOT/models"
  ) >"$DSV4_ROOT/logs/download.log" 2>&1 &
  download_pid=$!
else
  log 'Required model files are already present; reusing them.'
fi

build_started="$(date +%s)"
if [[ ! -x "$DSV4_ROOT/bin/llama-server" ]]; then
  log 'Building current llama.cpp with CUDA and the DeepSeek V4 multi-GPU scheduler limit.'
  if [[ ! -d "$DSV4_ROOT/src/llama.cpp/.git" ]]; then
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$DSV4_ROOT/src/llama.cpp" >/dev/null
  else
    git -C "$DSV4_ROOT/src/llama.cpp" fetch --depth 1 origin master >/dev/null
    git -C "$DSV4_ROOT/src/llama.cpp" reset --hard origin/master >/dev/null
  fi
  docker run --rm \
    --gpus all \
    -v "$DSV4_ROOT/src/llama.cpp:/src" -w /src "$CUDA_IMAGE" \
    bash -lc 'apt-get update -qq && apt-get install -y -qq build-essential cmake git >/dev/null && cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-DGGML_SCHED_MAX_SPLIT_INPUTS=48" -DCMAKE_CUDA_FLAGS="-DGGML_SCHED_MAX_SPLIT_INPUTS=48" >/dev/null && cmake --build build -j 16 --target llama-server >/dev/null'
  cp -a "$DSV4_ROOT/src/llama.cpp/build/bin/." "$DSV4_ROOT/bin/"
  chmod 755 "$DSV4_ROOT/bin/llama-server"
else
  log 'CUDA llama.cpp binary is already present; reusing it.'
fi
log "Runtime build: $(elapsed "$(( $(date +%s) - build_started ))")."

if [[ -n "$download_pid" ]]; then
  log 'Waiting for the resumable Xet download to finish. Live download log: dsv4 logs --download'
  wait "$download_pid"
fi
log "Model download: $(elapsed "$(( $(date +%s) - download_started ))")."
[[ -s "$DSV4_ROOT/models/$MODEL_FILE" && -s "$DSV4_ROOT/models/$DRAFT_FILE" ]] || { echo 'Required model files were not downloaded.' >&2; exit 1; }

install -d -m 700 /etc/dsv4
install -d -m 700 "$DSV4_ROOT/config"
if [[ ! -s "$DSV4_ROOT/config/credentials.env" ]]; then
  umask 077
  key="sk-dsv4-$(openssl rand -hex 32)"
  printf 'DSV4_API_KEY=%s\nLITELLM_MASTER_KEY=%s\n' "$key" "$key" > "$DSV4_ROOT/config/credentials.env"
elif ! grep -q '^LITELLM_MASTER_KEY=' "$DSV4_ROOT/config/credentials.env"; then
  key="$(awk -F= '/^DSV4_API_KEY=/{print $2; exit}' "$DSV4_ROOT/config/credentials.env")"
  printf 'LITELLM_MASTER_KEY=%s\n' "$key" >> "$DSV4_ROOT/config/credentials.env"
fi
ln -sfn "$DSV4_ROOT/config/credentials.env" /etc/dsv4/credentials.env
printf 'DSV4_ROOT=%q\nDSV4_MODEL_ALIAS=%q\nDSV4_GATEWAY_URL=%q\n' \
  "$DSV4_ROOT" "$MODEL_ALIAS" 'http://127.0.0.1:4000' > /etc/dsv4/dsv4.conf
chmod 600 "$DSV4_ROOT/config/credentials.env" /etc/dsv4/dsv4.conf

write_file 600 "$DSV4_ROOT/config/litellm.yaml" <<EOF
model_list:
  - model_name: $MODEL_ALIAS
    litellm_params:
      model: openai/$MODEL_ALIAS
      api_base: http://127.0.0.1:8000/v1
      api_key: dsv4-loopback-backend
litellm_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  drop_params: true
general_settings:
  disable_spend_logs: true
EOF

write_file 644 /etc/systemd/system/dsv4-llama.service <<EOF
[Unit]
Description=DeepSeek V4 Huihui GGUF llama.cpp server
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
TimeoutStartSec=infinity
TimeoutStopSec=90
ExecStartPre=-/usr/bin/docker rm -f dsv4-llama
ExecStart=/usr/bin/docker run --rm --name dsv4-llama --gpus all --network host --env LD_LIBRARY_PATH=/dsv4/bin -v $DSV4_ROOT:/dsv4 $CUDA_IMAGE /dsv4/bin/llama-server --model /dsv4/models/$MODEL_FILE --model-draft /dsv4/models/$DRAFT_FILE --spec-type draft-dspark --spec-draft-n-max 5 --fit off --n-gpu-layers 999 --n-gpu-layers-draft 999 --device CUDA0,CUDA1,CUDA2,CUDA3 --split-mode layer --flash-attn on --ctx-size 524288 --cache-type-k q8_0 --cache-type-v q8_0 --parallel 1 --reasoning-preserve --cont-batching --host 127.0.0.1 --port 8000
ExecStop=/usr/bin/docker stop -t 60 dsv4-llama

[Install]
WantedBy=multi-user.target
EOF

write_file 644 /etc/systemd/system/dsv4-gateway.service <<EOF
[Unit]
Description=Authenticated Anthropic-compatible DeepSeek gateway
After=dsv4-llama.service
Requires=dsv4-llama.service

[Service]
Type=simple
EnvironmentFile=/etc/dsv4/credentials.env
Environment=LITELLM_LOG=ERROR
Environment=NO_PROXY=127.0.0.1,localhost,::1
WorkingDirectory=$DSV4_ROOT
Restart=on-failure
RestartSec=5
ExecStart=$DSV4_ROOT/venv/bin/litellm --config $DSV4_ROOT/config/litellm.yaml --host 127.0.0.1 --port 4000

[Install]
WantedBy=multi-user.target
EOF

write_file 755 /usr/local/bin/dsv4 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
readonly CONF=/etc/dsv4/dsv4.conf
readonly CREDS=/etc/dsv4/credentials.env
[[ -r "$CONF" && -r "$CREDS" ]] || { echo 'dsv4: not installed' >&2; exit 1; }
source "$CONF"
root() { if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
key() { root awk -F= '/^DSV4_API_KEY=/{print $2; exit}' "$CREDS"; }
usage() { echo 'Usage: dsv4 {start|stop|restart|status|logs [--follow|--download]|credentials|update|uninstall --yes}'; }
case "${1:-}" in
  start|stop|restart) root systemctl "$1" dsv4-llama.service dsv4-gateway.service ;;
  status)
    printf 'llama.cpp: '; root systemctl is-active dsv4-llama.service || true
    printf 'gateway:   '; root systemctl is-active dsv4-gateway.service || true
    curl -fsS --max-time 5 http://127.0.0.1:8000/health >/dev/null && echo 'backend health: OK' || echo 'backend health: unavailable'
    curl -fsS --max-time 5 -H "Authorization: Bearer $(key)" "$DSV4_GATEWAY_URL/v1/models" >/dev/null && echo 'gateway auth: OK' || echo 'gateway auth: unavailable'
    ;;
  logs)
    if [[ "${2:-}" == '--download' ]]; then tail -n 120 "$DSV4_ROOT/logs/download.log"; elif [[ "${2:-}" == '--follow' || "${2:-}" == '-f' ]]; then root journalctl -fu dsv4-llama.service -u dsv4-gateway.service; else root journalctl --no-pager -n 200 -u dsv4-llama.service -u dsv4-gateway.service; fi
    ;;
  credentials) printf 'API KEY:\n%s\n\nMODEL:\n%s\n\nLOCAL GATEWAY:\n%s\n' "$(key)" "$DSV4_MODEL_ALIAS" "$DSV4_GATEWAY_URL" ;;
  update)
    echo 'Updating the gateway packages; the downloaded model and API key are retained.'
    root /usr/local/bin/uv pip install --python "$DSV4_ROOT/venv/bin/python" --upgrade 'litellm[proxy]>=1.80,<2' 'fastapi==0.115.12' >/dev/null
    root systemctl restart dsv4-gateway.service
    ;;
  uninstall)
    [[ "${2:-}" == '--yes' ]] || { echo "dsv4: permanently removes $DSV4_ROOT. Re-run: dsv4 uninstall --yes" >&2; exit 1; }
    [[ "$DSV4_ROOT" == /mnt/dsv4/* ]] || { echo 'dsv4: refusing unsafe target' >&2; exit 1; }
    root systemctl disable --now dsv4-gateway.service dsv4-llama.service || true
    root rm -f /etc/systemd/system/dsv4-gateway.service /etc/systemd/system/dsv4-llama.service /etc/dsv4/dsv4.conf /etc/dsv4/credentials.env /usr/local/bin/dsv4
    root systemctl daemon-reload
    root rm -rf -- "$DSV4_ROOT"
    ;;
  help|-h|--help|'') usage ;;
  *) echo "dsv4: unknown command '${1}'" >&2; usage; exit 1 ;;
esac
EOF

systemctl daemon-reload
runtime_started="$(date +%s)"
log 'Starting the private llama.cpp backend and authenticated gateway.'
systemctl enable --now dsv4-llama.service dsv4-gateway.service
for _ in $(seq 1 240); do
  if curl -fsS --max-time 5 http://127.0.0.1:8000/health >/dev/null \
    && curl -fsS --max-time 5 -H "Authorization: Bearer $(awk -F= '/^DSV4_API_KEY=/{print $2; exit}' /etc/dsv4/credentials.env)" http://127.0.0.1:4000/v1/models >/dev/null; then
    break
  fi
  sleep 5
done
curl -fsS --max-time 10 http://127.0.0.1:8000/health >/dev/null
curl -fsS --max-time 10 -H "Authorization: Bearer $(awk -F= '/^DSV4_API_KEY=/{print $2; exit}' /etc/dsv4/credentials.env)" http://127.0.0.1:4000/v1/models >/dev/null
log "Runtime initialization, model load, and JIT compilation: $(elapsed "$(( $(date +%s) - runtime_started ))")."
log "Total time until API readiness: $(elapsed "$(( $(date +%s) - STARTED_AT ))")."
key="$(awk -F= '/^DSV4_API_KEY=/{print $2; exit}' /etc/dsv4/credentials.env)"
cat <<EOF

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

ssh -L 4000:127.0.0.1:4000 root@$(hostname -I | awk '{print $1}')

Then configure OpenCode with this local gateway and API key.
========================================
EOF
