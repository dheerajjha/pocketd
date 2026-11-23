#!/usr/bin/env python3
"""Exercise the signing gate without a key, device, Apple account or network call."""
import importlib.util
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("pcc_signing", Path(__file__).with_name("pcc-signing.py"))
pcc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pcc)


class SigningGateTests(unittest.TestCase):
    def test_profile_authorizes_only_this_exact_identifier_and_boolean(self):
        for app, value, expected in [("test.pocketd", True, True), ("another.app", True, False),
                                     ("*", True, False), ("test.pocketd", "true", False), ("test.pocketd", False, False)]:
            profile = {"ApplicationIdentifierPrefix": ["TEST"], "Entitlements": {
                "application-identifier": "TEST." + app, pcc.PCC: value}}
            with self.subTest(app=app, value=value):
                self.assertEqual(pcc.profile_allows(profile, "test.pocketd"), expected)

    def test_stamp_matches_the_actual_target_and_profile_not_just_the_project_entitlement(self):
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            env = {"PRODUCT_BUNDLE_IDENTIFIER": "test.pocketd", "SCRIPT_INPUT_FILE_0": str(d / "target.plist"),
                   "SCRIPT_INPUT_FILE_1": str(d / "embedded.mobileprovision"), "SCRIPT_OUTPUT_FILE_0": str(d / "receipt.plist"),
                   "PLATFORM_NAME": "iphoneos", "EXPANDED_CODE_SIGN_IDENTITY": "fixture", "CODE_SIGNING_ALLOWED": "YES"}
            profile = {"ApplicationIdentifierPrefix": ["TEST"], "Entitlements": {"application-identifier": "TEST.test.pocketd", pcc.PCC: True}}
            def permits():
                pcc.stamp()
                return plistlib.loads((d / "receipt.plist").read_bytes())["permitsRequests"]
            with patch.dict(os.environ, env), patch.object(pcc, "read_profile", return_value=profile) as read:
                (d / "target.plist").write_bytes(plistlib.dumps({pcc.PCC: True}))
                self.assertTrue(permits())
                profile["Entitlements"].pop(pcc.PCC)
                with self.assertRaises(SystemExit): permits()
                read.reset_mock()
                with patch.dict(os.environ, {"CODE_SIGNING_ALLOWED": "NO"}): self.assertFalse(permits())
                with patch.dict(os.environ, {"EXPANDED_CODE_SIGN_IDENTITY": "-"}): self.assertFalse(permits())
                (d / "target.plist").write_bytes(plistlib.dumps({}))
                self.assertFalse(permits())
                read.assert_not_called()


if __name__ == "__main__": unittest.main()
