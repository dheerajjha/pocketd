#!/usr/bin/env python3
"""Run Pocketd's seven PCC UI scenarios and its Shortcut handoff case on a disposable iOS 27+ simulator.

On a GitHub-hosted runner: python3 scripts/test-pcc-ui.py --output <directory>
On a Mac: add --simulator <UDID> for an explicitly reserved, already booted iPhone.
Apple's service is never used. The negative control checks the QA build's real signing gate.
"""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

from pcc_ui_fixture import NAME, container

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "dev.pocketd.qa.pccui"
RUNNER = "dev.pocketd.ui.tests.xctrunner"
# One build, two clean installs. The Shortcut must see a true first launch;
# no GGUF is staged until the original suite explicitly asks for its fixture.
SUITES = (("ShortcutCloudHandoffTests", 1), ("PrivateCloudComputeTests", 7))
SIM = ["xcrun", "simctl"]
CAPTURES = ("01-onboarding-cloud-selected", "02-settings-cloud-selected", "03-ask-test-cloud-reply")


def output(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True, timeout=60).strip()


def run(*args, timeout=90):
    subprocess.run(args, check=True, cwd=ROOT, timeout=timeout)


def read_plist(path):
    return plistlib.loads(path.read_bytes())


def select_phone(udid):
    runtimes = json.loads(output(*SIM, "list", "runtimes", "-j"))["runtimes"]
    eligible = [r for r in runtimes if r.get("isAvailable") and ".iOS-" in r["identifier"]
                and int(r["version"].split(".")[0]) >= 27]
    if udid:
        device = str(uuid.UUID(udid)).upper()
        devices = json.loads(output(*SIM, "list", "devices", "available", "-j"))["devices"]
        for runtime in eligible:
            for phone in devices.get(runtime["identifier"], []):
                if (phone["udid"] == device and phone["state"] == "Booted"
                        and ".iPhone-" in phone.get("deviceTypeIdentifier", "")):
                    return device, runtime["version"], False
        raise ValueError("--simulator must be an explicitly reserved, booted iOS 27+ iPhone")
    if os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise ValueError("Supply --simulator on a shared or local Mac")
    for runtime in sorted(eligible, key=lambda r: tuple(map(int, r["version"].split("."))), reverse=True):
        phones = [t for t in runtime["supportedDeviceTypes"] if t.get("productFamily") == "iPhone"]
        if phones:
            model = next((p for p in phones if p["name"].endswith(" Pro")), phones[0])
            device = output(*SIM, "create", "Pocketd PCC UI " + uuid.uuid4().hex[:8], model["identifier"], runtime["identifier"])
            return device, runtime["version"], True
    raise RuntimeError("The selected Xcode has no available iOS 27+ iPhone runtime")


def prepare_plan(derived):
    plan, = (derived / "Build/Products").glob("*.xctestrun")
    spec = read_plist(plan)
    targets = [t for c in spec.get("TestConfigurations", []) for t in c["TestTargets"]]
    targets = targets or [t for t in spec.values() if isinstance(t, dict) and t.get("TestBundlePath")]
    target, = [t for t in targets if t.get("BlueprintName") == "PocketdUITests" and t.get("IsUITestBundle")]
    app, runner = (Path(target[key].replace("__TESTROOT__", str(plan.parent))).resolve()
                   for key in ("UITargetAppPath", "TestHostPath"))
    for path, identifier in [(app, BUNDLE), (runner, RUNNER)]:
        if not path.is_relative_to(plan.parent) or read_plist(path / "Info.plist")["CFBundleIdentifier"] != identifier:
            raise RuntimeError(f"Unexpected test plan product: {path}")
    if target.get("UITargetAppBundleIdentifier", BUNDLE) != BUNDLE:
        raise RuntimeError("The test plan targets a different application")
    receipt = read_plist(app / "PocketdCloudSigning.plist")
    if receipt.get("bundleID") != BUNDLE or receipt.get("permitsRequests") is not False:
        raise RuntimeError("The QA bundle must have a negative real PCC signing receipt")
    run("codesign", "--verify", "--strict", app)
    target.setdefault("EnvironmentVariables", {})["POCKETD_UI_INSTALLED_GGUF"] = NAME
    plan.write_bytes(plistlib.dumps(spec))
    return plan, app, runner, receipt


def exercise(device, plan, app, runner, result, suite, containers):
    for identifier in ("dev.pocketd.app", BUNDLE, RUNNER):
        for kind in ("app", "data"):
            installed = subprocess.run([*SIM, "get_app_container", device, identifier, kind], capture_output=True, timeout=30)
            if installed.returncode == 0:
                raise RuntimeError(f"Use a disposable simulator: {identifier} already has an {kind} container")
    owned, staging = [], None
    try:
        for path, identifier in [(app, BUNDLE), (runner, RUNNER)]:
            run(*SIM, "install", device, path)
            owned.append(identifier)
        data = container(device, BUNDLE)
        models = data / "Library/Application Support/Models"
        if data.name in containers.values() or (models.exists() and any(models.iterdir())):
            raise RuntimeError("Expected a fresh QA app container with no installed model")
        containers[suite] = data.name
        if suite == "PrivateCloudComputeTests":
            staging = subprocess.Popen([sys.executable, ROOT / "scripts/pcc_ui_fixture.py", device, BUNDLE, RUNNER])
        run("xcodebuild", "test-without-building", "-xctestrun", plan, "-destination", f"platform=iOS Simulator,id={device}",
            "-parallel-testing-enabled", "NO", f"-only-testing:PocketdUITests/{suite}", "-collect-test-diagnostics", "never",
            "-resultBundlePath", result, timeout=900)
        if staging is not None and staging.wait(timeout=10) != 0:
            raise RuntimeError("The GGUF staging handshake failed")
    finally:
        if staging is not None and staging.poll() is None:
            staging.terminate()
            staging.wait(timeout=10)
        for identifier in reversed(owned):
            subprocess.run([*SIM, "uninstall", device, identifier], check=False, timeout=60)


def export_screenshots(result, out, require_all):
    shots = out / "screenshots"
    run("xcrun", "xcresulttool", "export", "attachments", "--path", result, "--output-path", shots, "--filter", "*.png")
    # xcresulttool exports UUID filenames. Keep its manifest and expose the
    # three owner-facing captures by name, even if a later case fails.
    for case in json.loads((shots / "manifest.json").read_text()):
        for attachment in case["attachments"]:
            for name in CAPTURES:
                if name in attachment["suggestedHumanReadableName"]:
                    source, dest = shots / Path(attachment["exportedFileName"]).name, shots / (name + ".png")
                    if source != dest:
                        shutil.copyfile(source, dest)
    if require_all and not all((shots / (name + ".png")).is_file() for name in CAPTURES):
        raise RuntimeError("A required onboarding, Settings or Ask screenshot is missing")


def run_suites(device, plan, app, runner, out):
    counts, containers, errors = {}, {}, []
    for suite, expected in SUITES:
        result = out / (suite.removesuffix("Tests") + ".xcresult")
        try:
            exercise(device, plan, app, runner, result, suite, containers)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            errors.append(f"{suite}: {error}")
        try:
            summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result))
            (out / (result.stem + "-summary.json")).write_text(json.dumps(summary, indent=2) + "\n")
            counts[suite] = {key: summary[key] for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
            if summary["totalTestCount"] != expected or summary["passedTests"] != expected:
                errors.append(f"{suite}: expected {expected} passing cases, got {counts[suite]}")
            if suite == "PrivateCloudComputeTests":
                export_screenshots(result, out, require_all=summary["passedTests"] == expected)
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            errors.append(f"{suite} evidence: {error}")
    combined = {key: sum(c[key] for c in counts.values()) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
    combined.update(suites=counts, qaDataContainers=containers, errors=errors)
    (out / "summary.json").write_text(json.dumps(combined, indent=2) + "\n")
    if errors:
        raise RuntimeError("\n".join(errors))
    print(f"8/8 passed (1 Shortcut + 7 processing choices). Evidence: {out}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--simulator", metavar="UDID", help="reserved disposable iPhone; only GitHub-hosted runs create one")
    parser.add_argument("--output", required=True, type=Path, help="empty directory for the result bundle and screenshots")
    parser.add_argument("--packages", type=Path, help="optional SwiftPM checkout cache")
    args = parser.parse_args()
    if not args.simulator and (os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.environ.get("GITHUB_ACTIONS") != "true"):
        parser.error("--simulator is required outside a GitHub-hosted runner")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("--output must be empty; existing evidence will not be replaced")
    with tempfile.TemporaryDirectory(prefix="pocketd-pcc-ui-") as tmp:
        derived = Path(tmp).resolve() / "Derived"
        run("xcodegen", "generate")
        minimal = ROOT / "App/Resources/Pocketd-NoMemoryLimit.entitlements"
        cache = ["-clonedSourcePackagesDirPath", args.packages.resolve()] if args.packages else []
        run("xcodebuild", "-project", "Pocketd.xcodeproj", "-scheme", "Pocketd", "-configuration", "Debug",
            "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", derived, *cache,
            "-skipPackageUpdates", "-skipMacroValidation", "-hideShellScriptEnvironment", "-parallel-testing-enabled", "NO",
            *(f"-only-testing:PocketdUITests/{suite}" for suite, _ in SUITES),
            "CODE_SIGN_IDENTITY=-", f"POCKETD_BUNDLE_ID={BUNDLE}", f"POCKETD_ENTITLEMENTS={minimal}",
            f"POCKETD_WIDGET_ENTITLEMENTS={minimal}", "build-for-testing", timeout=2700)
        plan, app, runner, receipt = prepare_plan(derived)
        device, runtime, created = select_phone(args.simulator)
        try:
            evidence = {"commit": output("git", "rev-parse", "HEAD"), "xcode": output("xcodebuild", "-version"),
                        "runtime": runtime, "simulator": device, "signingReceipt": receipt}
            (out / "environment.json").write_text(json.dumps(evidence, indent=2) + "\n")
            print(json.dumps(evidence), flush=True)
            if created:
                run(*SIM, "bootstatus", device, "-b", timeout=300)
            run_suites(device, plan, app, runner, out)
        finally:
            if created:
                subprocess.run([*SIM, "shutdown", device], check=False, timeout=60)
                run(*SIM, "delete", device)


if __name__ == "__main__":
    main()
