#!/usr/bin/env bash
# Checks that every model in the catalogue can actually be downloaded.
#
# This exists because two entries — the first two rows of the list — answered
# 401 and 404 for weeks. The 401 was a gated Hugging Face repository, which
# cannot work without a token this app has no way to supply; the 404 was a
# filename that repository does not publish. Both were invisible until someone
# tapped Download, which is the first thing a new user does.
#
# Also compares the declared sizeBytes against the real Content-Length, because
# the memory fit badge is computed from it: an entry wrong by a gigabyte
# recommends a model the phone cannot hold.
set -u
cd "$(dirname "$0")/.."

fail=0
python3 - <<'PY' > /tmp/pocketd-catalogue.txt
import re, pathlib
s = pathlib.Path("Sources/PocketdKit/Models/ModelCatalog.swift").read_text()
for m in re.finditer(
    r'id:\s*"([^"]+)".*?repoID:\s*"([^"]+)".*?filename:\s*"([^"]+)".*?sizeBytes:\s*([0-9_]+)', s, re.S):
    print(m.group(1), m.group(2), m.group(3), m.group(4).replace("_", ""))
PY

while read -r id repo file declared; do
  url="https://huggingface.co/$repo/resolve/main/$file"
  headers=$(curl -sIL -m 30 "$url")
  code=$(printf '%s' "$headers" | grep -E '^HTTP/' | tail -1 | awk '{print $2}')
  actual=$(printf '%s' "$headers" | grep -i '^content-length' | tail -1 | tr -d '\r' | awk '{print $2}')

  if [ "${code:-000}" != "200" ]; then
    printf '  \033[31mFAIL\033[0m %-20s HTTP %s  %s\n' "$id" "${code:-000}" "$url"
    fail=$((fail+1)); continue
  fi
  # A fit badge computed from a size wrong by more than 10%% is a bad promise.
  drift=$(python3 -c "print(abs($actual - $declared) / max(1,$actual))")
  if python3 -c "import sys; sys.exit(0 if $drift > 0.10 else 1)"; then
    printf '  \033[31mFAIL\033[0m %-20s declared %s, actual %s\n' "$id" "$declared" "$actual"
    fail=$((fail+1))
  else
    printf '  \033[32mok\033[0m   %-20s %s bytes\n' "$id" "$actual"
  fi
done < /tmp/pocketd-catalogue.txt

echo
[ "$fail" -eq 0 ] && echo "catalogue is downloadable" || echo "$fail broken entries"
exit "$fail"
