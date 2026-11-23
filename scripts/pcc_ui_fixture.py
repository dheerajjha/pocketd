"""An offline GGUF small enough to load in the iOS simulator's real llama.cpp.

The host stages it only when the UI test has finished first-run onboarding:
weights present at first launch would correctly make Pocketd treat it as an upgrade.
"""
import json
import math
import os
import plistlib
import select
import struct
import subprocess
import sys
import time
import uuid
from contextlib import closing
from pathlib import Path

MODEL = "pcc-ui-local-fixture"
NAME = "Local picker test fixture"


def make_gguf():
    # GGUF v3, one Llama block, F32 weights and a 260-entry byte-fallback
    # vocabulary. The weights are synthetic: only actual residency is tested.
    def pack(fmt, *values):
        return struct.pack("<" + fmt, *values)

    def string(text):
        data = text.encode()
        return pack("Q", len(data)) + data

    fields = []

    def field(key, kind, data):
        fields.append(string(key) + pack("I", kind) + data)

    field("general.architecture", 8, string("llama"))
    field("general.name", 8, string(NAME))
    field("general.file_type", 4, pack("I", 0))
    for key, value in {"context_length": 512, "embedding_length": 32, "block_count": 1,
                       "feed_forward_length": 64, "attention.head_count": 1,
                       "attention.head_count_kv": 1, "rope.dimension_count": 32}.items():
        field("llama." + key, 4, pack("I", value))
    field("llama.attention.layer_norm_rms_epsilon", 6, pack("f", 1e-5))
    field("tokenizer.ggml.model", 8, string("llama"))
    tokens = ["<unk>", "<s>", "</s>", "▁"] + [f"<0x{n:02X}>" for n in range(256)]
    count = len(tokens)
    for key, kind, data in [
        ("tokens", 8, b"".join(map(string, tokens))),
        ("scores", 6, pack("f", 0) * count),
        ("token_type", 5, pack("iiii", 2, 3, 3, 1) + pack("i", 6) * 256),
    ]:
        field("tokenizer.ggml." + key, 9, pack("IQ", kind, count) + data)
    for key, value in [("unknown", 0), ("bos", 1), ("eos", 2)]:
        field(f"tokenizer.ggml.{key}_token_id", 4, pack("I", value))
    field("tokenizer.chat_template", 8, string("{% for m in messages %}{{ m['content'] }}\n{% endfor %}"))

    tensors = [("token_embd.weight", [32, count]), ("output_norm.weight", [32]),
               ("output.weight", [32, count]), ("blk.0.attn_norm.weight", [32]),
               ("blk.0.ffn_norm.weight", [32])]
    tensors += [(f"blk.0.attn_{n}.weight", [32, 32]) for n in ("q", "k", "v", "output")]
    tensors += [("blk.0.ffn_gate.weight", [32, 64]), ("blk.0.ffn_up.weight", [32, 64]),
                ("blk.0.ffn_down.weight", [64, 32])]
    table, data = bytearray(), bytearray()
    for name, dims in tensors:
        table += string(name) + pack("I", len(dims)) + b"".join(pack("Q", n) for n in dims)
        table += pack("IQ", 0, len(data))
        data += pack("f", 1 if "norm" in name else 0) * math.prod(dims)
        data += bytes(-len(data) % 32)
    header = b"GGUF" + pack("IQQ", 3, len(tensors), len(fields)) + b"".join(fields) + table
    return header + bytes(-len(header) % 32) + data


def container(device, identifier):
    path = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, identifier, "data"],
                                        text=True, timeout=120).strip())
    metadata = plistlib.loads((path / ".com.apple.mobile_container_manager.metadata.plist").read_bytes())
    if metadata["MCMMetadataIdentifier"] != identifier:
        raise RuntimeError(f"Wrong container for {identifier}")
    return path


def stage(device, bundle, runner, shortcut=None):
    device = str(uuid.UUID(device)).upper()  # Never the ambiguous `booted` alias.
    if not bundle.startswith("dev.pocketd.qa.") or runner != "dev.pocketd.ui.tests.xctrunner":
        raise ValueError("Only the separate QA app and test runner may be used")
    docs = container(device, runner) / "Documents"
    docs.mkdir(exist_ok=True)
    if shortcut is not None and (len(shortcut) != 8 or not shortcut.isascii() or not shortcut.isdecimal()):
        raise ValueError("Expected an eight-digit synthetic Shortcut challenge")
    kind = "shortcut-" + shortcut if shortcut else "stage"
    request, ready = docs / f"pcc-ui-{kind}-request", docs / f"pcc-ui-{kind}-ready"
    deadline = time.monotonic() + 600
    fd = os.open(docs, os.O_EVTONLY)
    try:
        with closing(select.kqueue()) as queue:
            queue.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE, flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                         fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_DELETE)], 0, 0)
            while not request.is_file():
                if not queue.control(None, 1, max(0, deadline - time.monotonic())):
                    raise TimeoutError(f"The UI runner did not request {kind}")
    finally:
        os.close(fd)
    if shortcut:
        # By the time this one-shot signal exists, XCTest has installed its
        # products. Deliver a cold launch with no prior provider or onboarding override.
        if ready.exists():
            raise RuntimeError("The external Shortcut was already delivered")
        subprocess.run(["xcrun", "simctl", "launch", device, bundle, "-pocketd.testPCC", "available",
                        "-pocketd.proOverride", "off", "-pocketd.analyticsConsent", "refused",
                        "-pocketd.serverShouldRun", "NO", "-pocketd.calendarTools", "NO", "-pocketd.reminderTools", "NO",
                        "-pocketd.healthTools", "NO", "-pocketd.siriAsk", shortcut], check=True, timeout=210)
        ready.touch(exist_ok=False)
        return
    models = container(device, bundle) / "Library/Application Support/Models"
    models.mkdir(parents=True, exist_ok=True)
    if any(models.iterdir()) or ready.exists():
        raise RuntimeError("Will not replace existing model data or a previous test marker")
    weights = make_gguf()
    with (models / (MODEL + ".gguf")).open("xb") as f:
        f.write(weights)
    record = dict(id=MODEL, displayName=NAME, repoID="fixture/local", filename=MODEL + ".gguf", parameters="0B",
                  quantization="F32", sizeBytes=len(weights), contextLength=512, license="Synthetic", toolSupport="no")
    with (models / "manifest.json").open("x") as f:
        json.dump({MODEL: record}, f)
    ready.touch(exist_ok=False)
    print(f"Staged {len(weights)} local GGUF bytes in the QA app", flush=True)


if __name__ == "__main__":
    stage(*sys.argv[1:])
