# Contributing

## Getting set up

```bash
brew install xcodegen
git clone https://github.com/dheerajjha/pocketd
cd pocketd
make test     # the package: about a second, no simulator
make app      # generates Pocketd.xcodeproj
```

Optionally, `reference/sync.sh` shallow-clones the projects this one learns
from — Ollama and llama.cpp for the two wire formats, and the iOS apps solving
the same problem. The folder is git-ignored. Read them before inventing
anything: nearly every compatibility rule in this repository came from one of
those sources rather than from a guess.

## Where to start

Roughly by how long it takes:

1. **A model in the catalogue** (~5 minutes) — add a `ModelRecord` to
   `ModelCatalog.swift`. `sizeBytes` must be the real file size, because the
   memory-fit badge is computed from it and an entry that is wrong by a gigabyte
   is worse than no entry at all.

2. **A client compatibility fix** (~30 minutes) — if some client refuses to talk
   to `pocketd`, the fix belongs in `Routes+OpenAI.swift` or `Routes+Ollama.swift`.
   Bring a test that captures the exact shape the client wanted, and say in a
   comment which client and which field.

3. **A new backend** (~half a day) — conform to `InferenceEngine`. That protocol
   is the only thing the server knows about inference; MLX and Apple's
   Foundation Models are both reachable through LocalLLMClient already.

## The rules that matter

**Route changes need a test that goes over real HTTP.** `TestServer` boots a
listener on a kernel-assigned port and talks to it with `URLSession`. Calling
handlers directly would pass while the SSE framing, the header names and the
status codes were all wrong — which is exactly the layer third-party clients
depend on.

**Keep the package free of inference dependencies.** `PocketdKit` depends on an
HTTP server and nothing else. That is what makes the test suite run in a second
on a Linux runner instead of fifteen minutes on a macOS one. If you find
yourself importing LocalLLMClient into `Sources/`, the thing you want is
probably a new method on `InferenceEngine`.

**Comment the why, not the what.** The tricky parts of this repository are all
about someone else's constraints — iOS closing sockets on suspend, Ollama
streaming by default where OpenAI does not, a Go struct without `omitempty`.
A comment that records which constraint a line is serving survives; one that
restates the line does not.

**Do not claim capabilities we do not have.** The `capabilities` array in
`/api/tags`, the `usage` numbers, the memory fit badge — a client or a user acts
on all three. An honest gap is better than a plausible fiction.

## Before opening a pull request

```bash
make test
make build-sim   # slow: compiles llama.cpp
```
