#!/usr/bin/env python3
"""Stamp the host app's PCC signing status, or verify the final signed .app/.xcarchive."""
import os
import plistlib
import subprocess
import sys
from pathlib import Path

PCC = "com.apple.developer.private-cloud-compute"
RECEIPT = "PocketdCloudSigning.plist"


def profile_allows(profile, identifier):
    entitlements = profile.get("Entitlements", {})
    app_id = entitlements.get("application-identifier", "")
    # A managed capability is authorized for an explicit App ID, never a wildcard.
    return (entitlements.get(PCC) is True and bool(identifier)
            and any(app_id == f"{prefix}.{identifier}" for prefix in profile.get("ApplicationIdentifierPrefix", [])))


def read_profile(path):
    decoded = subprocess.check_output(["/usr/bin/security", "cms", "-D", "-i", str(path)], stderr=subprocess.DEVNULL)
    return plistlib.loads(decoded)


def stamp():
    entitlements, profile, output = (Path(os.environ[key]) for key in ("SCRIPT_INPUT_FILE_0", "SCRIPT_INPUT_FILE_1", "SCRIPT_OUTPUT_FILE_0"))
    identifier = os.environ["PRODUCT_BUNDLE_IDENTIFIER"]
    requested = plistlib.loads(entitlements.read_bytes()).get(PCC) is True
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "")
    signed = os.environ.get("CODE_SIGNING_ALLOWED") == "YES" and identity not in ("", "-")
    allowed = signed and requested and profile.suffix == ".mobileprovision" and profile_allows(read_profile(profile), identifier)
    if signed and requested and os.environ.get("PLATFORM_NAME") == "iphoneos" and not allowed:
        raise SystemExit("Pocketd's selected profile does not authorize Private Cloud Compute for this App ID.")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(plistlib.dumps({"bundleID": identifier, "permitsRequests": allowed}, fmt=plistlib.FMT_BINARY))


def verify(path):
    if path.suffix == ".xcarchive":
        (path,) = (path / "Products/Applications").glob("*.app")
    identifier = plistlib.loads((path / "Info.plist").read_bytes())["CFBundleIdentifier"]
    receipt = plistlib.loads((path / RECEIPT).read_bytes())
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R=anchor apple generic", str(path)], check=True)
    signature = subprocess.check_output(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)], stderr=subprocess.DEVNULL)
    signed = plistlib.loads(signature) if signature else {}
    if receipt != {"bundleID": identifier, "permitsRequests": True} or signed.get(PCC) is not True:
        raise SystemExit("This is not a PCC-enabled signed Pocketd app.")
    profile = path / "embedded.mobileprovision"
    if profile.exists() and not profile_allows(read_profile(profile), identifier):
        raise SystemExit("The embedded profile does not authorize PCC for this app.")
    print(f"{identifier}: Private Cloud Compute is present in the signed application.")


if __name__ == "__main__":
    if sys.argv[1:] == ["stamp"]:
        stamp()
    elif len(sys.argv) == 3 and sys.argv[1] == "verify":
        verify(Path(sys.argv[2]))
    else:
        raise SystemExit("Usage: pcc-signing.py stamp | verify <app or xcarchive>")
