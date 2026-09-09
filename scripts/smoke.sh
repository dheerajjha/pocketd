#!/usr/bin/env bash
# Exercises a running pocketd from another machine, the way a client would.
#
# The package tests cover the same routes against a mock engine. This covers what
# they cannot: a real model, a real device, and a real network hop.
#
#   ./scripts/smoke.sh http://192.168.1.42:11434 pk-yourkey
set -u

BASE="${1:-http://127.0.0.1:11434}"
KEY="${2:-}"
MODEL="${3:-}"

pass=0; fail=0
AUTH=(); [ -n "$KEY" ] && AUTH=(-H "Authorization: Bearer $KEY")

check() { # name, expected, actual
  if [ "$2" = "$3" ]; then
    printf '  \033[32mok\033[0m   %-46s %s\n' "$1" "$3"; pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m %-46s got %s, want %s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}

contains() { # name, needle, haystack
  case "$3" in
    *"$2"*) printf '  \033[32mok\033[0m   %-46s\n' "$1"; pass=$((pass+1));;
    *)      printf '  \033[31mFAIL\033[0m %-46s missing %s\n' "$1" "$2"; fail=$((fail+1))
            printf '       body: %.240s\n' "$3";;
  esac
}

status() { curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "$@"; }

echo "== reachability"
check "GET /health" 200 "$(status "$BASE/health")"
check "GET / (Ollama probe)" 200 "$(status "$BASE/")"
check "HEAD /" 200 "$(curl -s -o /dev/null -w '%{http_code}' -I "${AUTH[@]}" "$BASE/")"
contains "root says Ollama is running" "Ollama is running" "$(curl -s "$BASE/")"

HEALTH=$(curl -s "$BASE/health")
echo "  backend: $(echo "$HEALTH" | sed -n 's/.*"backend":"\([^"]*\)".*/\1/p')"
echo "  model:   $(echo "$HEALTH" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')"
[ -z "$MODEL" ] && MODEL=$(echo "$HEALTH" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')

echo
echo "== auth"
if [ -n "$KEY" ]; then
  check "no key is rejected" 401 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/models")"
  check "wrong key is rejected" 401 "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer pk-wrong' "$BASE/v1/models")"
  check "right key is accepted" 200 "$(status "$BASE/v1/models")"
else
  echo "  (auth disabled on the server, skipping)"
fi

echo
echo "== OpenAI dialect"
contains "GET /v1/models lists $MODEL" "\"$MODEL\"" "$(curl -s "${AUTH[@]}" "$BASE/v1/models")"
check "GET /v1/models/$MODEL" 200 "$(status "$BASE/v1/models/$MODEL")"
check "GET /v1/models/nope is 404" 404 "$(status "$BASE/v1/models/nope")"

BUF=$(curl -s "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: PONG\"}],\"max_tokens\":24,\"stream\":false}" \
  "$BASE/v1/chat/completions")
contains "buffered completion has content" '"content"' "$BUF"
contains "buffered completion reports usage" '"total_tokens"' "$BUF"
contains "buffered completion is stamped" 'pocketd-' "$BUF"
echo "  said: $(echo "$BUF" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -c 120)"

STREAM=$(curl -s -N "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Count: one two three\"}],\"max_tokens\":24,\"stream\":true}" \
  "$BASE/v1/chat/completions")
contains "SSE frames are prefixed" 'data: ' "$STREAM"
contains "SSE terminates with [DONE]" 'data: [DONE]' "$STREAM"
contains "first chunk opens the role" '"role":"assistant"' "$STREAM"
contains "final chunk carries a finish reason" '"finish_reason":"' "$STREAM"
CHUNKS=$(printf '%s' "$STREAM" | grep -c '^data: ' || true)
if [ "${CHUNKS:-0}" -gt 3 ]; then
  printf '  \033[32mok\033[0m   %-46s %s frames\n' "streamed incrementally" "$CHUNKS"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m %-46s only %s frames (buffered?)\n' "streamed incrementally" "${CHUNKS:-0}"; fail=$((fail+1))
fi

USAGE=$(curl -s -N "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":16,\"stream\":true,\"stream_options\":{\"include_usage\":true}}" \
  "$BASE/v1/chat/completions")
contains "stream_options yields a usage chunk" '"usage"' "$USAGE"
contains "usage chunk has empty choices" '"choices":[]' "$USAGE"

check "POST /v1/embeddings is 501, not 404" 501 "$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -d '{}' "$BASE/v1/embeddings")"

echo
echo "== Ollama dialect"
TAGS=$(curl -s "${AUTH[@]}" "$BASE/api/tags")
contains "GET /api/tags lists $MODEL" "\"$MODEL\"" "$TAGS"
contains "tags carry parent_model" '"parent_model"' "$TAGS"
contains "tags carry families" '"families"' "$TAGS"
contains "tags carry capabilities" '"capabilities"' "$TAGS"
contains "GET /api/version is semver" '"version":"0.' "$(curl -s "${AUTH[@]}" "$BASE/api/version")"
contains "GET /api/ps reports the resident model" "\"$MODEL\"" "$(curl -s "${AUTH[@]}" "$BASE/api/ps")"

NDJSON=$(curl -s -N "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"stream\":true,\"options\":{\"num_predict\":24}}" \
  "$BASE/api/chat")
if printf '%s' "$NDJSON" | grep -q '^data: '; then
  printf '  \033[31mFAIL\033[0m %-46s SSE prefix on an Ollama route\n' "/api/chat streams NDJSON"; fail=$((fail+1))
else
  printf '  \033[32mok\033[0m   %-46s\n' "/api/chat streams NDJSON, not SSE"; pass=$((pass+1))
fi
contains "NDJSON terminates with done:true" '"done":true' "$NDJSON"
contains "NDJSON carries a done_reason" '"done_reason"' "$NDJSON"

GEN=$(curl -s "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"Say hello\",\"stream\":false,\"options\":{\"num_predict\":24}}" \
  "$BASE/api/generate")
contains "/api/generate answers buffered" '"response"' "$GEN"
echo "  said: $(echo "$GEN" | sed -n 's/.*"response":"\([^"]*\)".*/\1/p' | head -c 120)"

echo
echo "== errors"
check "unknown model is 404" 404 "$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"model":"nope","messages":[{"role":"user","content":"x"}]}' "$BASE/v1/chat/completions")"
check "malformed body is 400" 400 "$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -d '{ not json' "$BASE/v1/chat/completions")"

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
