#!/usr/bin/env bash
# Evaluate the actual product catalogue and URL getters. Scraping Swift text can
# silently skip a row or a projector and still report success. No shared temp file.
set -euo pipefail
cd "$(dirname "$0")/.."

cat Sources/PocketdKit/Models/{GGUFMetadata,MemoryEstimate,ModelCapabilities,ModelRecord,ModelCatalog}.swift - <<'SWIFT' | swift - | python3 scripts/verify_catalogue.py
struct Entry: Encodable {
    let model: ModelRecord
    let weights: URL
    let projector: URL?
}
let entries = ModelCatalog.all.map { Entry(model: $0, weights: $0.downloadURL, projector: $0.projectorURL) }
FileHandle.standardOutput.write(try JSONEncoder().encode(entries))
SWIFT
