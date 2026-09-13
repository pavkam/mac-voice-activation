#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
# SPDX-License-Identifier: MIT

"""Exercise packaging with inert tools; never build, sign, or touch a Keychain."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class BuildAppTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="yapops-packaging-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copyfile(Path(__file__).with_name("build-app.sh"), scripts / "build-app.sh")
        resources = self.root / "Sources/YapOpsApp/Resources"
        resources.mkdir(parents=True)
        for name in ["Info.plist", "YapOps.icns"] + [
            name + ".wav" for name in [
                "AgentThinking", "CaptureEnd", "CaptureStart", "ToolComplete", "ToolFailed", "ToolStart"
            ]
        ]:
            (resources / name).write_text("inert resource")
        self.app = self.root / ".build/YapOps.app"
        (self.app / "Contents").mkdir(parents=True)
        # A stale prior build's Contents/, to be replaced by a successful
        # rebuild but preserved if this rebuild fails.
        (self.app / "Contents/previous-build").write_text("keep until signing succeeds")
        # A marker outside Contents/, at the bundle's own top level. The build
        # must never recreate that top-level directory - only its Contents/ -
        # so this must survive every rebuild, successful or not.
        (self.app / "bundle-directory-marker").write_text("must outlive every rebuild")
        self.bin = self.root / "tools"
        self.bin.mkdir()
        stub = f"#!{sys.executable}\n" + '''
import json, os
from pathlib import Path
import sys
root = Path(os.environ["PACKAGING_TEST_ROOT"])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "swift":
    binary = root / ".build/bin"
    binary.mkdir(parents=True, exist_ok=True)
    (binary / "YapOps").write_text("new executable")
    if "--show-bin-path" in args:
        print(binary)
elif name == "codesign":
    with (root / "signing.jsonl").open("a") as output:
        output.write(json.dumps(args) + "\\n")
    if "--sign" in args and os.environ.get("FAIL_SIGN") == "1":
        sys.exit(1)
    if "--verify" in args and os.environ.get("FAIL_VERIFY") == "1":
        sys.exit(1)
'''
        for name in ["swift", "codesign", "plutil"]:
            executable = self.bin / name
            executable.write_text(stub)
            executable.chmod(0o755)

    def build(self, **overrides):
        environment = dict(os.environ)
        environment.pop("SIGN_IDENTITY", None)
        environment.update({
            "PACKAGING_TEST_ROOT": str(self.root),
            "PATH": str(self.bin) + os.pathsep + environment["PATH"],
            **overrides,
        })
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts/build-app.sh")],
            env=environment, capture_output=True, text=True, timeout=15,
        )

    def signing_identity(self):
        calls = [json.loads(line) for line in (self.root / "signing.jsonl").read_text().splitlines()]
        signing = next(args for args in calls if "--sign" in args)
        return signing[signing.index("--sign") + 1]

    def test_local_build_reuses_named_identity_by_default(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.signing_identity(), "YapOps Local Development")
        self.assertTrue((self.app / "Contents/MacOS/YapOps").exists())
        self.assertFalse((self.app / "Contents/previous-build").exists())

    def test_successful_build_never_recreates_the_bundle_directory(self):
        """The whole point of the in-place Contents/ swap: a stray file
        living outside Contents/, at the bundle's own top level, must survive
        a successful rebuild untouched. Recreating that directory (rather than
        updating it in place) is exactly what let macOS Accessibility/TCC
        trust go stale across rebuilds with an otherwise identical, persistent
        signing identity."""
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.app / "bundle-directory-marker").exists())

    def test_explicit_signing_identity_is_preserved_as_one_argument(self):
        result = self.build(SIGN_IDENTITY="Apple Development: Fixture (TEST)")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.signing_identity(), "Apple Development: Fixture (TEST)")

    def test_adhoc_requires_explicit_override(self):
        result = self.build(SIGN_IDENTITY="-")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.signing_identity(), "-")

    def test_failed_signing_keeps_previous_app_without_falling_back(self):
        result = self.build(FAIL_SIGN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.app / "Contents/previous-build").exists())
        self.assertTrue((self.app / "bundle-directory-marker").exists())
        self.assertEqual(self.signing_identity(), "YapOps Local Development")
        self.assertEqual(list((self.root / ".build").glob("YapOps-package.*")), [])

    def test_failed_verification_keeps_previous_app(self):
        result = self.build(FAIL_VERIFY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.app / "Contents/previous-build").exists())
        self.assertTrue((self.app / "bundle-directory-marker").exists())
        self.assertEqual(list((self.root / ".build").glob("YapOps-package.*")), [])


if __name__ == "__main__":
    unittest.main()
