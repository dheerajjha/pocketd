#!/usr/bin/env bash
# Shallow-clones the projects worth reading before inventing anything.
# Depth 1 because we want the current shape of the code, not its history.
set -u
cd "$(dirname "$0")"

clone() { # repo, dir, [sparse paths...]
  local url="$1" dir="$2"; shift 2
  if [ -d "$dir/.git" ]; then echo "== $dir (have it)"; return; fi
  echo "== $dir"
  if [ "$#" -gt 0 ]; then
    git clone --depth 1 --filter=blob:none --sparse "$url" "$dir" -q || return
    (cd "$dir" && git sparse-checkout set "$@")
  else
    git clone --depth 1 "$url" "$dir" -q || return
  fi
}

# The two API dialects we implement. These are the specification.
clone https://github.com/ollama/ollama.git                 ollama            api server docs
clone https://github.com/ggml-org/llama.cpp.git            llama.cpp         tools/server examples/llama.swiftui

# iOS apps solving the same problem, in the two dominant architectures.
clone https://github.com/a-ghorbani/pocketpal-ai.git       pocketpal-ai
clone https://github.com/guinmoon/LLMFarm.git              LLMFarm
clone https://github.com/mainframecomputer/fullmoon-ios.git fullmoon-ios

# Our inference dependency, and the HTTP server under our routes.
clone https://github.com/tattn/LocalLLMClient.git          LocalLLMClient
clone https://github.com/swhitty/FlyingFox.git             FlyingFox
