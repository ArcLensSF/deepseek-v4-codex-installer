# DeepSeek V4 private server installer

This repository is a public, one-command installer for a **private self-hosted model server**. It deploys `sakamakismile/DeepSeek-V4-Flash-0731-Abliterated-NVFP4` for trusted users running Codex CLI; it does not create a public API, accounts, billing, a dashboard, or SaaS infrastructure.

## Security boundary

| Component | Default listener | Authentication |
| --- | --- | --- |
| vLLM backend | `127.0.0.1:8000` | None; never exposed off-host |
| LiteLLM OpenAI Responses gateway | `127.0.0.1:4000` | Generated 256-bit `sk-dsv4-…` key |

Both trusted users connect through their own SSH tunnel. The unauthenticated vLLM backend is hard-restricted to loopback.

## Install

Use a fresh CUDA-enabled Linux image where `nvidia-smi` works. The primary supported configurations are 2× or 4× RTX PRO 6000 Blackwell 96 GB GPUs. Ubuntu 22.04/24.04, Debian 12, RHEL-compatible distributions, and Fedora are supported.

After publishing, replace `OWNER/REPO` with the real GitHub path:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | bash
```

The installer detects GPUs and storage; installs Linux dependencies, uv, Python 3.12, vLLM, LiteLLM, Hugging Face, and Xet; and requires 250 GB free by default. It uses `HF_XET_HIGH_PERFORMANCE=1` and a content-addressed Hugging Face snapshot, so it does not create a second ~176 GB model copy. Interrupted downloads, caches, configuration, virtual environment, compiled kernels, and the API key are reused on rerun.

```bash
# Select a known ephemeral NVMe mount.
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | DSV4_ROOT=/mnt/ephemeral/dsv4 bash

# Deliberate storage/context overrides.
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | DSV4_MIN_FREE_GB=300 DSV4_MAX_MODEL_LEN=262144 bash
```

The server uses tensor parallelism equal to detected GPU count, FP8 KV cache, DeepSeek V4 reasoning/tool parsing, expert parallelism, a 524,288-token context window, and Blackwell-oriented serving settings. It prints download, runtime initialization, model-load-to-health, JIT/kernel warm-up, and overall readiness timing.

## Connect Codex CLI from a laptop

Codex CLI custom model providers use the OpenAI **Responses API**, so this installer provides an authenticated Responses gateway rather than an Anthropic gateway. It verifies a real `/v1/responses` request before reporting readiness.

```bash
ssh -L 4000:127.0.0.1:4000 USER@SERVER_IP

# If Codex CLI is not already installed:
curl -fsSL https://chatgpt.com/codex/install.sh | sh

mkdir -p ~/.codex
cp /path/to/this/repository/templates/codex/dsv4.config.toml ~/.codex/dsv4.config.toml
export DSV4_API_KEY="sk-dsv4-..."

codex --profile dsv4
```

The profile uses `http://127.0.0.1:4000/v1` and does not modify a user’s normal Codex configuration. The installer prints its full profile and the key on completion; the server owner can retrieve them later using `dsv4 credentials`. Codex documents custom provider `base_url`, environment-key authentication, and its Responses-only provider protocol in the [official configuration reference](https://developers.openai.com/codex/config-reference/).

This only substitutes private model inference. Codex’s local shell and repository tools work normally, while OpenAI-hosted features such as standalone web search are not available from this private provider.

## Server management

```text
dsv4 start
dsv4 stop
dsv4 restart
dsv4 status
dsv4 logs
dsv4 credentials
dsv4 update
dsv4 uninstall --yes
```

`dsv4 update` refreshes the installed Python serving packages and restarts the server without removing the model cache or API key. `dsv4 uninstall --yes` is explicit because it removes both credentials and the cached model.

The selected data root contains the Hugging Face/Xet cache, uv cache, Torch/Triton compilation cache, Python 3.12 environment, runtime config, and timing state. The only secret is `/etc/dsv4/credentials.env`, owned by root with mode `600`.

## Safety and operations

NVIDIA drivers are a prerequisite supplied by the GPU image. The installer only installs user-space dependencies and refuses to download the model if `nvidia-smi` is unavailable.

The checkpoint is an abliterated derivative with intentionally modified refusal behavior. Restrict it to trusted users, comply with its Hugging Face license, and do not use it for sensitive or safety-critical decisions.

The default gateway is loopback-only. A non-loopback gateway requires both `DSV4_GATEWAY_HOST=…` and `DSV4_ALLOW_PUBLIC_GATEWAY=1`; the operator must then provide TLS and firewalling. vLLM can never be made public through an installer flag.

## Checks

```bash
./tests/run.sh
```

These checks require neither a GPU nor a model download. The same suite runs in GitHub Actions.

## License

Installer code is MIT licensed; the checkpoint has separate terms on Hugging Face.
