import importlib.util
import json
import os
import stat
import struct
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("runtime_compat.py")
SPEC = importlib.util.spec_from_file_location("runtime_compat", MODULE_PATH)
runtime_compat = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(runtime_compat)


class RuntimeInventoryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.previous_out = runtime_compat.OUT
        runtime_compat.OUT = Path(self.temporary.name)
        root = runtime_compat.install_root("linux-x64")
        root.mkdir(parents=True)
        for index, name in enumerate(runtime_compat.RUNTIME_NAMES):
            # Enough of an ELF header for the verifier: magic, little-endian,
            # and e_machine=x86_64. Unique tails make the digests distinct.
            header = bytearray(64)
            header[:4] = b"\x7fELF"
            header[4] = 2
            header[5] = 1
            header[18:20] = struct.pack("<H", 62)
            artifact = runtime_compat.installed_path(name, "linux-x64")
            artifact.write_bytes(header + bytes([index]))
            artifact.chmod(artifact.stat().st_mode | stat.S_IXUSR)

    def tearDown(self):
        runtime_compat.OUT = self.previous_out
        self.temporary.cleanup()

    def test_inventory_round_trip_uses_stable_install_layout(self):
        written = runtime_compat.write_inventory("linux-x64")
        verified = runtime_compat.verify_inventory("linux-x64")
        self.assertEqual(written, verified)
        self.assertEqual(
            [entry["name"] for entry in verified["artifacts"]],
            list(runtime_compat.RUNTIME_NAMES),
        )
        self.assertEqual(
            runtime_compat.inventory_path("linux-x64").parent.parts[-3:],
            ("runtimes", "linux", "x86_64"),
        )

    def test_digest_tampering_fails_packaging_verification(self):
        runtime_compat.write_inventory("linux-x64")
        artifact = runtime_compat.installed_path("stormdns", "linux-x64")
        contents = bytearray(artifact.read_bytes())
        contents[-1] ^= 0xFF
        artifact.write_bytes(contents)
        with self.assertRaisesRegex(RuntimeError, "digest mismatch"):
            runtime_compat.verify_inventory("linux-x64")

    def test_missing_artifact_fails_packaging_verification(self):
        runtime_compat.write_inventory("linux-x64")
        runtime_compat.installed_path("olcrtc", "linux-x64").unlink()
        with self.assertRaisesRegex(RuntimeError, "missing"):
            runtime_compat.verify_inventory("linux-x64")

    def test_release_matrix_excludes_unclaimed_arm_targets(self):
        self.assertEqual(
            set(runtime_compat.MANIFEST["targets"]),
            {"linux-x64", "windows-x64", "macos-x64", "macos-arm64"},
        )


if __name__ == "__main__":
    unittest.main()
