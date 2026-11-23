#!/usr/bin/env python3
"""Combine independent simulator results without treating a missing run as a pass."""
import json
import shutil
import subprocess
import sys
from pathlib import Path


def collect(parts, output, commit):
    suites = {"shortcut": 1, "picker": 7, "download": 1}
    keys = ("totalTestCount", "passedTests", "failedTests", "skippedTests")
    totals = dict.fromkeys(keys, 0)
    counts, errors = {}, []
    output.mkdir(parents=True, exist_ok=False)
    shots = output / "screenshots"
    shots.mkdir()
    for name, expected in suites.items():
        try:
            part, = parts.glob(f"pcc-part-*-{name}")
            env = json.loads((part / "environment.json").read_text())
            if env["commit"] != commit or env["signingReceipt"].get("permitsRequests") is not False:
                raise ValueError("wrong source or real cloud signing receipt")
            bundle, = part.glob("*.xcresult")
            raw = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                                      "--path", bundle], timeout=180))
            counts[name] = {key: raw[key] for key in keys}
            for key in keys:
                totals[key] += counts[name][key]
            if counts[name] != dict(zip(keys, (expected, expected, 0, 0))):
                errors.append(f"{name}: expected {expected} passes, got {counts[name]}")
            summary = json.loads((part / "summary.json").read_text())
            if summary["suite"] != name or summary.get("errors") or any(summary[key] != counts[name][key] for key in keys):
                errors.append(f"{name}: the worker did not verify this result")
            if name == "picker":
                for stem in ("01-onboarding-cloud-selected", "02-settings-cloud-selected", "03-ask-test-cloud-reply"):
                    image = part / "screenshots" / (stem + ".png")
                    if not image.is_file() or image.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
                        errors.append(f"Missing {stem}.png")
                    else:
                        shutil.copyfile(image, shots / image.name)
        except (OSError, TypeError, ValueError, KeyError, subprocess.SubprocessError) as error:
            errors.append(f"{name}: {error}")
    proof = dict(commit=commit, suites=counts, errors=errors, **totals)
    (output / "summary.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(json.dumps(proof, indent=2))
    return not errors


if __name__ == "__main__":
    sys.exit(0 if collect(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]) else 1)
