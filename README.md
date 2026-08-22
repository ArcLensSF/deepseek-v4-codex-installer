# Private Huihui DeepSeek V4 Flash server

This public repository installs a private, self-hosted model server. It does not create a public API, user accounts, billing, or SaaS infrastructure.

It serves [`huihui-ai/Huihui-DeepSeek-V4-Flash-0731-abliterated-GGUF`](https://huggingface.co/huihui-ai/Huihui-DeepSeek-V4-Flash-0731-abliterated-GGUF): the `DeepSeek-V4-Flash-Q4-mxfp4-0731.gguf` main model plus the matching BF16 DSpark draft model.

## What it installs

- Latest CUDA-enabled `llama.cpp`, built for Blackwell (`SM120`)
- Layer-split model and DSpark draft decoding across 4× RTX PRO 6000 Blackwell 96 GB GPUs
- 524,288-token context in one full request slot
- Flash Attention and llama.cpp's supported 8-bit `q8_0` KV cache
- Hugging Face Xet with `HF_XET_HIGH_PERFORMANCE=1`; only the two required GGUF files are downloaded
- A loopback-only llama.cpp backend at `127.0.0.1:8000`
- An authenticated OpenAI- and Anthropic-compatible LiteLLM gateway at `127.0.0.1:4000`
- A persistent, mode-`600` API-key file on the selected model volume
- `dsv4 start|stop|restart|status|logs|credentials|update|uninstall`

The backend is never published outside the host. Connect from a trusted laptop through SSH tunneling.

## Hardware and storage

This profile requires 4× RTX PRO 6000 Blackwell GPUs (at least 90 GB each) and about 190 GiB of empty local/persistent storage before the initial download. The completed main model is about 156 GB and its DSpark draft is about 11.3 GB.

When a block volume is mounted at `/mnt/dsv4`, it is selected automatically. Otherwise the installer chooses the largest local disk. To force a persistent volume explicitly:

```bash
DSV4_ROOT=/mnt/dsv4/dsv4-huihui-gguf \
curl -fsSL https://raw.githubusercontent.com/ArcLensSF/deepseek-v4-codex-installer/main/install.sh | bash
```

## Install

SSH to the GPU host as root, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/ArcLensSF/deepseek-v4-codex-installer/main/install.sh | bash
```

The installer is resumable. Re-running it retains downloaded GGUF files, the compiled llama.cpp runtime, Xet data, the Python environment, configuration, and the API key. `dsv4 credentials` prints the generated key without changing it.

## Use from a laptop

Keep this tunnel open:

```bash
ssh -N -L 4000:127.0.0.1:4000 root@SERVER_IP
```

Then retrieve the key securely from the server when needed:

```bash
ssh root@SERVER_IP dsv4 credentials
```

For OpenCode, configure an OpenAI-compatible provider with:

```text
base URL: http://127.0.0.1:4000/v1
API key:  the value from dsv4 credentials
model:    dsv4-huihui-0731-abliterated
```

For Claude Code:

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:4000"
export ANTHROPIC_AUTH_TOKEN="sk-dsv4-…"
export ANTHROPIC_MODEL="dsv4-huihui-0731-abliterated"
claude
```

## Operations

```bash
dsv4 status
dsv4 logs --follow
dsv4 logs --download
dsv4 credentials
dsv4 restart
```

`dsv4 uninstall --yes` permanently removes the selected model root and its persistent key.
