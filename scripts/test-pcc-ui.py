#!/usr/bin/env python3
"""Run one PCC UI suite on a fresh, single-screen iOS 27+ iPhone simulator.

Build once with --build-only TAR_GZ. On each fresh GitHub host, pass
--from-build TAR_GZ --suite {shortcut,picker,download} --output DIRECTORY.
Locally, also supply --simulator UDID for an explicitly reserved, booted iPhone.
"""
import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from contextlib import contextmanager
from pathlib import Path

from pcc_ui_fixture import BUNDLE, NAME, seed_installed_model

ROOT = Path(__file__).resolve().parents[1]
RUNNER = "dev.pocketd.ui.tests.xctrunner"
PICKER = "PocketdUITests/PrivateCloudComputeTests"
DOWNLOAD = PICKER + "/testInstalledDownloadReplacesCloudAndSurvivesRelaunch"
SUITES = {
    "shortcut": (1, ["-only-testing:PocketdUITests/ShortcutCloudHandoffTests"]),
    "picker": (7, [f"-only-testing:{PICKER}", f"-skip-testing:{DOWNLOAD}"]),
    "download": (1, [f"-only-testing:{DOWNLOAD}"]),
}
SIM = ["xcrun", "simctl"]
CAPTURES = ("01-onboarding-cloud-selected", "02-settings-cloud-selected", "03-ask-test-cloud-reply")
COUNTS = ("totalTestCount", "passedTests", "failedTests", "skippedTests")


def output(*args, timeout=60):
    return subprocess.check_output(args, cwd=ROOT, text=True, timeout=timeout).strip()


def run(*args, timeout=90, env=None):
    subprocess.run(args, check=True, cwd=ROOT, timeout=timeout, env=env)


def read_plist(path):
    return plistlib.loads(path.read_bytes())


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def github_hosted():
    return os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted" and os.environ.get("GITHUB_ACTIONS") == "true"


def select_phone(reserved):
    if not reserved and not github_hosted():
        raise ValueError("Supply --simulator on a shared or local Mac")
    reserved = str(uuid.UUID(reserved)).upper() if reserved else None
    inventory = json.loads(output(*SIM, "list", "-j"))
    # Device-specific runtimes have a hardware suffix, e.g. iOS-27-2-iPhone19-4.
    runtimes = [r for r in inventory["runtimes"] if r.get("isAvailable")
                and re.fullmatch(r".+\.iOS-\d+(?:-\d+)*", r["identifier"]) and int(r["version"].split(".")[0]) >= 27]

    def regular(type_id):
        return ".iPhone-" in type_id and "duo" not in type_id.lower()

    def rank(type_id, runtime):
        model = type_id.rsplit(".", 1)[-1]
        preferred = ("iPhone-15-Pro", "iPhone-17", "iPhone-17-Pro", "iPhone-16", "iPhone-16-Pro")
        return (-preferred.index(model) if model in preferred else -len(preferred), model.endswith("-Pro"),
                tuple(map(int, runtime["version"].split("."))))

    phones = [(p, r) for r in runtimes for p in inventory["devices"].get(r["identifier"], [])
              if regular(p.get("deviceTypeIdentifier", "")) and p.get("isAvailable") and p["state"] in ("Booted", "Shutdown")]
    if reserved:
        phones = [(p, r) for p, r in phones if p["udid"] == reserved and p["state"] == "Booted"]
        if not phones:
            raise ValueError("--simulator must be a reserved, booted, single-screen iOS 27+ iPhone")
    if phones:
        phone, runtime = max(phones, key=lambda pr: (pr[0]["state"] == "Booted", rank(pr[0]["deviceTypeIdentifier"], pr[1])))
    else:
        types = [(t, r) for r in runtimes for t in r["supportedDeviceTypes"] if regular(t["identifier"])]
        if not types:
            raise RuntimeError("No standard iOS 27+ iPhone simulator runtime is available")
        model, runtime = max(types, key=lambda tr: rank(tr[0]["identifier"], tr[1]))
        device = output(*SIM, "create", model["name"], model["identifier"], runtime["identifier"])
        phone = dict(udid=device, name=model["name"], deviceTypeIdentifier=model["identifier"])
    if not reserved:  # Exclusive hosted VM only: leave RAM for one phone, even if the image prebooted another.
        for group in inventory["devices"].values():
            for other in group:
                if other["state"] in ("Booted", "Booting") and other["udid"] != phone["udid"]:
                    run(*SIM, "shutdown", other["udid"], timeout=180)
    return dict(simulator=phone["udid"], deviceName=phone["name"], deviceTypeIdentifier=phone["deviceTypeIdentifier"],
                runtime=runtime["version"], runtimeIdentifier=runtime["identifier"])


def prepare_plan(products):
    products = products.resolve(strict=True)
    plan, = (path for path in products.glob("*.xctestrun") if not path.name.startswith("."))
    spec = read_plist(plan)
    targets = [t for c in spec.get("TestConfigurations", []) for t in c["TestTargets"]]
    targets = targets or [t for t in spec.values() if isinstance(t, dict) and t.get("TestBundlePath")]
    target, = [t for t in targets if t.get("BlueprintName") == "PocketdUITests" and t.get("IsUITestBundle")]
    if (target.get("UseDestinationArtifacts") or target.get("TestHostBundleIdentifier", RUNNER) != RUNNER
            or target.get("UITargetAppBundleIdentifier", BUNDLE) != BUNDLE):
        raise RuntimeError("Expected XCTest to install the QA app and runner from the generated simulator plan")

    def product(ref):
        path = (products / ref.removeprefix("__TESTROOT__/")).resolve(strict=True)
        if not ref.startswith("__TESTROOT__/") or not path.is_relative_to(products):
            raise RuntimeError(f"Non-relocatable test plan product: {ref}")
        return path

    app, runner = (product(target[key]) for key in ("UITargetAppPath", "TestHostPath"))
    tests = product(target["TestBundlePath"].replace("__TESTHOST__", target["TestHostPath"]))
    if not tests.is_relative_to(runner):
        raise RuntimeError("The test bundle must be inside the QA runner")
    # Pack the whole simulator configuration (including framework search paths), not host-only build products.
    dependencies = [product(ref) for ref in target["DependentProductPaths"]]
    product_roots = sorted({p.relative_to(products).parts[0] for p in (app, runner, *dependencies)})
    for key in ("EnvironmentVariables", "TestingEnvironmentVariables", "UITargetAppEnvironmentVariables"):
        if any(name.startswith("POCKETD_UI_") for name in target.get(key, {})):
            raise RuntimeError("The shared test plan must not bake in a suite-specific fixture")
    for path, identifier in ((app, BUNDLE), (runner, RUNNER), (tests, "dev.pocketd.ui.tests")):
        info = read_plist(path / "Info.plist")
        if info.get("CFBundleIdentifier") != identifier or "iPhoneSimulator" not in info.get("CFBundleSupportedPlatforms", []):
            raise RuntimeError(f"Wrong simulator product: {path}")
    receipt = read_plist(app / "PocketdCloudSigning.plist")
    if receipt.get("bundleID") != BUNDLE or receipt.get("permitsRequests") is not False:
        raise RuntimeError("The QA bundle must have a negative real PCC signing receipt")
    run("codesign", "--verify", "--strict", app, runner)
    return plan, app, receipt, product_roots


def installed_apps(device):
    # A missing-app lookup can hang on a newly booted simulator. Read the
    # registry once and require a known positive before trusting any absence.
    raw = subprocess.check_output([*SIM, "listapps", device], timeout=180)
    xml = subprocess.run(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", "-"], input=raw,
                         stdout=subprocess.PIPE, check=True, timeout=15).stdout
    apps = plistlib.loads(xml)
    if apps.get("com.apple.Preferences", {}).get("CFBundleIdentifier") != "com.apple.Preferences":
        raise RuntimeError("The simulator application registry did not report Settings")
    return apps


@contextmanager
def record_errors(errors, operation):
    try:
        yield
    except (OSError, KeyError, ValueError, RuntimeError, TypeError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        errors.append(f"{operation}: {error}")
        print(errors[-1], file=sys.stderr, flush=True)


def exercise(device, reserved, plan, app, result, suite, errors):
    clean = False
    try:
        with record_errors(errors, suite):
            if not reserved:
                run(*SIM, "bootstatus", device, "-b", timeout=360)
            existing = {"dev.pocketd.app", BUNDLE, RUNNER}.intersection(installed_apps(device))
            if existing:
                raise RuntimeError(f"Use a fresh simulator: already installed: {', '.join(sorted(existing))}")
            clean = True
            env = {k: v for k, v in os.environ.items() if not k.startswith(("POCKETD_UI_", "TEST_RUNNER_POCKETD_UI_"))}
            if suite == "download":
                run(*SIM, "install", device, app, timeout=180)
                seed_installed_model(device)
                # xcodebuild strips TEST_RUNNER_ when forwarding a variable to the test host.
                env["TEST_RUNNER_POCKETD_UI_INSTALLED_GGUF"] = NAME
            run("xcodebuild", "test-without-building", "-xctestrun", plan, "-destination", f"platform=iOS Simulator,id={device}",
                "-parallel-testing-enabled", "NO", *SUITES[suite][1], "-collect-test-diagnostics", "never",
                "-resultBundlePath", result, timeout=1800, env=env)
    finally:
        if not reserved:
            # A slow shutdown of this disposable VM must not hide XCTest's result.
            try:
                run(*SIM, "shutdown", device, timeout=180)
            except (OSError, subprocess.SubprocessError) as error:
                print(f"Hosted simulator shutdown: {error}", file=sys.stderr, flush=True)
        elif clean:
            with record_errors(errors, "local cleanup"):
                apps = installed_apps(device)
                for identifier in (RUNNER, BUNDLE):
                    if identifier in apps:
                        with record_errors(errors, f"uninstall {identifier}"):
                            run(*SIM, "uninstall", device, identifier, timeout=120)


def export_screenshots(result, out):
    shots = out / "screenshots"
    run("xcrun", "xcresulttool", "export", "attachments", "--path", result, "--output-path", shots, "--filter", "*.png", timeout=240)
    # xcresulttool exports UUID filenames. Keep its manifest and expose the
    # three owner-facing captures by name, even if a later case fails.
    for case in json.loads((shots / "manifest.json").read_text()):
        for attachment in case["attachments"]:
            for name in CAPTURES:
                if name in attachment["suggestedHumanReadableName"]:
                    source, dest = shots / Path(attachment["exportedFileName"]).name, shots / (name + ".png")
                    if source != dest:
                        shutil.copyfile(source, dest)
    if not all((shots / (name + ".png")).is_file() for name in CAPTURES):
        raise RuntimeError("A required onboarding, Settings or Ask screenshot is missing")


def collect_result(result, suite, summary):
    if not result.is_dir():
        raise RuntimeError("XCTest did not produce a result bundle")
    with record_errors(summary["errors"], "XCTest summary"):
        raw = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result, timeout=240))
        counts = {key: raw[key] for key in COUNTS}
        if any(type(n) is not int or n < 0 for n in counts.values()):
            raise ValueError(f"Invalid XCTest counts: {counts}")
        summary.update(counts)
        expected = SUITES[suite][0]
        if tuple(counts.values()) != (expected, expected, 0, 0):
            raise RuntimeError(f"Expected {expected} passes, got {counts}")
    if suite == "picker":
        with record_errors(summary["errors"], "picker screenshots"):
            export_screenshots(result, result.parent)


def build(derived, packages):
    run("xcodegen", "generate")
    minimal = ROOT / "App/Resources/Pocketd-NoMemoryLimit.entitlements"
    cache = ["-clonedSourcePackagesDirPath", packages.resolve()] if packages else []
    run("xcodebuild", "-project", "Pocketd.xcodeproj", "-scheme", "Pocketd", "-configuration", "Debug",
        "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", derived, "-jobs", "3", *cache,
        "-skipPackageUpdates", "-skipMacroValidation", "-hideShellScriptEnvironment", "-parallel-testing-enabled", "NO",
        "-only-testing:PocketdUITests", "CODE_SIGN_IDENTITY=-", f"POCKETD_BUNDLE_ID={BUNDLE}", f"POCKETD_ENTITLEMENTS={minimal}",
        f"POCKETD_WIDGET_ENTITLEMENTS={minimal}", "build-for-testing", timeout=2700)


def prepare_products(args, derived, stamp):
    products = derived / "Build/Products"
    if args.from_build:
        products.mkdir(parents=True)
        run("/usr/bin/tar", "-xzf", args.from_build.resolve(), "-C", products, timeout=300)
        if json.loads((products / "pcc-build.json").read_text()) != stamp:
            raise RuntimeError("The test products do not match this commit and Xcode")
    else:
        build(derived, args.packages)
    plan, app, receipt, product_roots = prepare_plan(products)
    if args.build_only:
        write_json(products / "pcc-build.json", stamp)
        run("/usr/bin/tar", "-czf", args.build_only.resolve(), "-C", products, "pcc-build.json", plan.name, *product_roots, timeout=300)
    return plan, app, receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--simulator", metavar="UDID", help="reserved disposable iPhone; required for local tests")
    parser.add_argument("--output", type=Path, help="empty directory for the test results and screenshots")
    parser.add_argument("--suite", choices=SUITES, help="one independent suite; required for test execution")
    parser.add_argument("--packages", type=Path, help="optional SwiftPM checkout cache")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--build-only", type=Path, metavar="TAR_GZ", help="package this build for a fresh simulator host")
    group.add_argument("--from-build", type=Path, metavar="TAR_GZ", help="run the matching build-only product")
    args = parser.parse_args()
    if args.build_only:
        if args.build_only.exists() or args.output or args.simulator or args.suite:
            parser.error("--build-only needs an unused archive path and takes no --suite, --output or --simulator")
    else:
        if not args.simulator and not github_hosted():
            parser.error("--simulator is required outside a GitHub-hosted runner")
        if not args.output or not args.suite:
            parser.error("--suite and --output are required for test execution")
        out = args.output.resolve()
        out.mkdir(parents=True, exist_ok=True)
        if any(out.iterdir()):
            parser.error("--output must be empty; existing evidence will not be replaced")
    stamp = {"commit": output("git", "rev-parse", "HEAD"), "xcode": output("xcodebuild", "-version")}
    with tempfile.TemporaryDirectory(prefix="pocketd-pcc-ui-") as tmp:
        derived = Path(tmp).resolve() / "Derived"
        if args.build_only:
            prepare_products(args, derived, stamp)
            return
        evidence = dict(stamp, suite=args.suite)
        summary = dict.fromkeys(COUNTS, 0)
        summary.update(suite=args.suite, errors=[])
        with record_errors(summary["errors"], args.suite):
            try:
                plan, app, receipt = prepare_products(args, derived, stamp)
                evidence["signingReceipt"] = receipt
                evidence.update(select_phone(args.simulator))
            finally:
                write_json(out / "environment.json", evidence)
            print(json.dumps(evidence), flush=True)
            result = out / (args.suite + ".xcresult")
            exercise(evidence["simulator"], args.simulator, plan, app, result, args.suite, summary["errors"])
            collect_result(result, args.suite, summary)
        write_json(out / "summary.json", summary)
        if summary["errors"]:
            raise SystemExit(1)
        print(f"{args.suite}: {summary['passedTests']}/{summary['totalTestCount']} passed. Evidence: {out}")


if __name__ == "__main__":
    main()
