from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = (ROOT / "install.sh").read_text()
INSTALLER = (ROOT / "scripts" / "install-huihui-gguf-remote.sh").read_text()


class HuihuiInstallerContractTests(unittest.TestCase):
    def test_public_bootstrap_fetches_the_versioned_installer(self):
        self.assertIn("scripts/install-huihui-gguf-remote.sh", BOOTSTRAP)
        self.assertIn("curl --fail --location", BOOTSTRAP)
        self.assertIn("set -Eeuo pipefail", BOOTSTRAP)

    def test_exact_checkpoint_files_are_pinned(self):
        self.assertIn("huihui-ai/Huihui-DeepSeek-V4-Flash-0731-abliterated-GGUF", INSTALLER)
        self.assertIn("DeepSeek-V4-Flash-Q4-mxfp4-0731.gguf", INSTALLER)
        self.assertIn("dspark-DeepSeek-V4-Flash-0731-BF16.gguf", INSTALLER)
        self.assertIn("--revision", INSTALLER)
        self.assertIn("HF_XET_HIGH_PERFORMANCE=1", INSTALLER)
        self.assertIn("--local-dir", INSTALLER)

    def test_private_loopback_topology_and_authentication(self):
        self.assertIn("--host 127.0.0.1 --port 8000", INSTALLER)
        self.assertIn("--host 127.0.0.1 --port 4000", INSTALLER)
        self.assertIn("LITELLM_MASTER_KEY", INSTALLER)
        self.assertIn("sk-dsv4-", INSTALLER)
        self.assertIn("chmod 600", INSTALLER)

    def test_blackwell_dspark_profile(self):
        self.assertIn("rtx pro 6000 blackwell", INSTALLER)
        self.assertIn("--spec-type draft-dspark", INSTALLER)
        self.assertIn("--spec-draft-n-max 5", INSTALLER)
        self.assertIn("--ctx-size 524288", INSTALLER)
        self.assertIn("--parallel 1", INSTALLER)
        self.assertIn("--cache-type-k q8_0", INSTALLER)
        self.assertIn("--reasoning-preserve", INSTALLER)
        self.assertIn("GGML_SCHED_MAX_SPLIT_INPUTS=48", INSTALLER)

    def test_management_cli_contract(self):
        for command in ("start|stop|restart", "status)", "logs)", "credentials)", "update)", "uninstall)"):
            self.assertIn(command, INSTALLER)


if __name__ == "__main__":
    unittest.main()
