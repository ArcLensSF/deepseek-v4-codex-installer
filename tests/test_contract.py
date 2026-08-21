from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "install.sh").read_text()
PROFILE = (ROOT / "templates/codex/dsv4.config.toml").read_text()
GATEWAY_TEMPLATE = (ROOT / "templates/systemd/dsv4-gateway.service.template").read_text()
VLLM_TEMPLATE = (ROOT / "templates/systemd/dsv4-vllm.service.template").read_text()


class InstallerContractTests(unittest.TestCase):
    def test_secure_shell_baseline(self):
        self.assertIn("set -Eeuo pipefail", INSTALLER)
        self.assertIn("umask 077", INSTALLER)
        self.assertIn("--proto '=https'", INSTALLER)
        self.assertIn("--tlsv1.2", INSTALLER)

    def test_exact_checkpoint_and_single_cache_snapshot(self):
        self.assertIn("amesianx/DeepSeek-V4-Flash-DSpark-Abliterated", INSTALLER)
        self.assertIn("HF_XET_HIGH_PERFORMANCE=1", INSTALLER)
        self.assertIn("snapshot_download(", INSTALLER)
        self.assertIn("HF_HUB_CACHE", INSTALLER)
        self.assertNotIn("local_dir=", INSTALLER)
        self.assertIn('recorded_model="$(<"$DSV4_STATE/model-id"', INSTALLER)
        self.assertIn('"$recorded_model" == "$MODEL_ID"', INSTALLER)

    def test_vllm_is_loopback_only_and_has_required_flags(self):
        self.assertIn('[[ "$DSV4_VLLM_HOST" == "127.0.0.1" ]]', INSTALLER)
        self.assertIn("--host \"$DSV4_VLLM_HOST\"", INSTALLER)
        self.assertNotIn("DSV4_VLLM_HOST:-0.0.0.0", INSTALLER)
        for flag in (
            "--tensor-parallel-size \"$GPU_COUNT\"",
            "--kv-cache-dtype fp8",
            "--max-model-len \"$DSV4_MAX_MODEL_LEN\"",
            "--tool-call-parser deepseek_v4",
            "--reasoning-parser deepseek_v4",
            "--enable-auto-tool-choice",
            "--speculative-config '{\"method\":\"dspark\",\"num_speculative_tokens\":5,\"draft_sample_method\":\"probabilistic\"}'",
        ):
            self.assertIn(flag, INSTALLER)
        self.assertIn("native FP8 decoder and FP4 expert formats", INSTALLER)

    def test_credential_handling(self):
        self.assertIn("openssl rand -hex 32", INSTALLER)
        self.assertIn("sk-dsv4-", INSTALLER)
        self.assertIn("/etc/dsv4/credentials.env", INSTALLER)
        self.assertIn("-m 600", INSTALLER)
        self.assertIn("EnvironmentFile=/etc/dsv4/credentials.env", INSTALLER)
        self.assertNotRegex(INSTALLER, r"sk-dsv4-[0-9a-fA-F]{64}")

    def test_codex_responses_gateway_contract(self):
        self.assertIn("/v1/responses", INSTALLER)
        self.assertIn('wire_api = "responses"', INSTALLER)
        self.assertIn('model_provider = "dsv4"', PROFILE)
        self.assertIn('env_key = "DSV4_API_KEY"', PROFILE)
        self.assertIn('base_url = "http://127.0.0.1:4000/v1"', PROFILE)
        self.assertNotIn("ANTHROPIC_", INSTALLER)
        self.assertNotIn("claude", INSTALLER.lower())

    def test_management_commands_and_safe_uninstall(self):
        for command in ("start", "stop", "restart", "status", "logs", "credentials", "update", "uninstall"):
            self.assertRegex(INSTALLER, rf"\b{command}\b")
        self.assertIn("dsv4 uninstall --yes", INSTALLER)
        self.assertIn("refusing unsafe removal target", INSTALLER)

    def test_service_templates_preserve_boundary(self):
        self.assertIn("Description=DeepSeek V4 vLLM backend (loopback only)", VLLM_TEMPLATE)
        self.assertIn("EnvironmentFile=/etc/dsv4/credentials.env", GATEWAY_TEMPLATE)
        self.assertIn("NoNewPrivileges=true", VLLM_TEMPLATE)
        self.assertIn("NoNewPrivileges=true", GATEWAY_TEMPLATE)


if __name__ == "__main__":
    unittest.main()
