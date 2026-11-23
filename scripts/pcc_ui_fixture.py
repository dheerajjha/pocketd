"""Seed the download suite's fresh QA install with a real, offline llama.cpp model."""
import json
import math
import plistlib
import struct
import subprocess
import uuid
from pathlib import Path

BUNDLE = "dev.pocketd.qa.pccui"
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


def seed_installed_model(device):
    device = str(uuid.UUID(device)).upper()  # Never the ambiguous `booted` alias.
    data = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, BUNDLE, "data"],
                                        text=True, timeout=180).strip()).resolve(strict=True)
    metadata = plistlib.loads((data / ".com.apple.mobile_container_manager.metadata.plist").read_bytes())
    if (data.parts[-6:-1] != (device, "data", "Containers", "Data", "Application")
            or metadata.get("MCMMetadataIdentifier") != BUNDLE):
        raise RuntimeError(f"Wrong simulator data container for {BUNDLE}: {data}")
    support = data / "Library/Application Support"
    models = support / "Models"
    if (models.resolve() != models or any(p != models for p in support.glob("*")) or any(models.glob("*"))
            or any((data / "Documents").glob("*")) or (data / "Library/Preferences" / (BUNDLE + ".plist")).exists()):
        raise RuntimeError("Refusing to seed a QA container with existing app data")
    models.mkdir(parents=True, exist_ok=True)
    weights = make_gguf()
    with (models / (MODEL + ".gguf")).open("xb") as f:
        f.write(weights)
    record = dict(id=MODEL, displayName=NAME, repoID="fixture/local", filename=MODEL + ".gguf", parameters="0B",
                  quantization="F32", sizeBytes=len(weights), contextLength=512, license="Synthetic", toolSupport="no")
    with (models / "manifest.json").open("x") as f:
        json.dump({MODEL: record}, f)
    print(f"Seeded {len(weights)} offline GGUF bytes in {BUNDLE} ({data.name})", flush=True)
