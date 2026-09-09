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
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
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
# The root serves two audiences by Accept header; breaking either one is silent.
contains "a browser gets the setup page" "<!doctype html>" "$(curl -s -H 'Accept: text/html' "$BASE/")"
contains "an Ollama client does not" "Ollama is running" "$(curl -s -H 'Accept: */*' "$BASE/")"
check "GET /setup" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/setup")"
check "an unopened pairing code is refused" 403 "$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"code":"000000"}' "$BASE/pair")"

HEALTH=$(curl -s "$BASE/health")
echo "  backend: $(echo "$HEALTH" | sed -n 's/.*"backend":"\([^"]*\)".*/\1/p')"
echo "  model:   $(echo "$HEALTH" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')"
[ -z "$MODEL" ] && MODEL=$(echo "$HEALTH" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')

# Waits until the server will accept work again, so a slow generation started by
# one check — or by a previous invocation of this script — cannot make the next
# one fail with a 503 it did not cause.
wait_idle() {
  for _ in $(seq 1 200); do
    code=$(curl -s -o /dev/null -m 60 -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
      "$BASE/v1/chat/completions")
    [ "$code" = "503" ] || return 0
    sleep 2
  done
  return 1
}

wait_idle || echo "  (warning: server busy at start)"

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

# The case the short requests above cannot catch: a non-streamed completion
# writes nothing until the last token, so a server whose connection timeout is
# tuned for web traffic kills every substantial response with an empty 500.
echo "  (long generation, this takes a minute...)"
LONG=$(curl -s -m 900 -w '\nHTTP_STATUS:%{http_code} SECONDS:%{time_total}' "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a long detailed essay about the ocean.\"}],\"max_tokens\":600,\"stream\":false}" \
  "$BASE/v1/chat/completions")
LONG_CODE=$(printf '%s' "$LONG" | sed -n 's/.*HTTP_STATUS:\([0-9]*\).*/\1/p')
LONG_SECS=$(printf '%s' "$LONG" | sed -n 's/.*SECONDS:\([0-9.]*\).*/\1/p')
check "long buffered completion survives (${LONG_SECS}s)" 200 "$LONG_CODE"
[ "$LONG_CODE" = "200" ] || printf '       body: %.300s\n' "$LONG"
contains "long completion has content" '"content"' "$LONG"

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
echo "== behaviour under load"

# The server admits one generation at a time; a second must be refused fast
# rather than queued until the client gives up.
curl -s -o /dev/null -m 300 "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a long essay about rivers\"}],\"max_tokens\":400,\"stream\":false}" \
  "$BASE/v1/chat/completions" >/dev/null 2>&1 &
LOADPID=$!
# Poll rather than sleeping a fixed interval: how long the background
# generation takes depends on the model and the device, and a fixed wait makes
# this pass or fail by luck. A flaky check is worse than no check.
# Wait until /health confirms a generation is actually in flight. Probing on a
# timer raced the background request, which sometimes lost and took the 503
# itself — a flaky check is worse than no check.
BUSY=000
for _ in $(seq 1 30); do
  ACTIVE=$(curl -s -m 10 "$BASE/health" | sed -n 's/.*"activeRequests":\([0-9]*\).*/\1/p')
  if [ "${ACTIVE:-0}" -ge 1 ]; then
    BUSY=$(curl -s -o /dev/null -m 30 -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}" \
      "$BASE/v1/chat/completions")
    break
  fi
  kill -0 "$LOADPID" 2>/dev/null || break
  sleep 1
done
check "a second concurrent request is refused fast" 503 "$BUSY"
wait "$LOADPID" 2>/dev/null || true
wait_idle || echo "  (warning: server did not go idle)"

# A stream the client abandons must not wedge the single generation slot.
curl -s -N -m 2 "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a long essay about mountains\"}],\"max_tokens\":400,\"stream\":true}" \
  "$BASE/v1/chat/completions" >/dev/null 2>&1 || true
if wait_idle; then
  printf '  \033[32mok\033[0m   %-46s\n' "an abandoned stream frees the slot"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m %-46s slot never freed\n' "an abandoned stream frees the slot"; fail=$((fail+1))
fi

# Freeing the slot is not enough. A generation stopped mid-decode leaves the KV
# and prompt caches describing tokens that were never finished, and the next
# request reuses that prefix: the server keeps answering 200 while the model
# emits an empty string or a run of punctuation. Status codes cannot see this,
# so the check reads the words.
# Rebuilding the context after a cancellation adds latency to the first request
# that follows, so settle before sampling or this races its own warm-up.
wait_idle || true
AFTER=$(curl -s -m 300 "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one short sentence.\"}],\"max_tokens\":24}" \
  "$BASE/v1/chat/completions")
SANE=$(printf '%s' "$AFTER" | python3 -c "
import sys, json, re
try:
    text = json.load(sys.stdin)['choices'][0]['message']['content']
except Exception:
    print('unparseable'); raise SystemExit
# The two observed corruption signatures are an empty string and a run of
# punctuation like '()()()()'. Nothing here judges quality: a 360M model
# answering 'Hi' is correct, and two earlier versions of this check failed it
# by demanding a minimum length. Test only what actually distinguishes a
# poisoned context from a terse answer.
stripped = text.strip()
letters = len(re.findall(r'[A-Za-z]', stripped))
ratio = letters / len(stripped) if stripped else 0
print('ok' if letters >= 1 and ratio >= 0.5 else 'garbage:' + repr(text[:60]))
")
if [ "$SANE" = "ok" ]; then
  printf '  \033[32mok\033[0m   %-46s\n' "the model still talks sense afterwards"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m %-46s %s\n' "the model still talks sense afterwards" "$SANE"; fail=$((fail+1))
fi
wait_idle || true

# A prompt far past the context cap must fail cleanly rather than hang or crash.
python3 - "$MODEL" > "$TMP/big.json" <<'PYJSON'
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": "word " * 20000}],
    "max_tokens": 16,
}))
PYJSON
OVER=$(curl -s -o /dev/null -m 300 -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' \
  --data-binary @"$TMP/big.json" "$BASE/v1/chat/completions")
case "$OVER" in
  200|413|500)
    printf '  \033[32mok\033[0m   %-46s %s\n' "an oversized prompt answers, not hangs" "$OVER"; pass=$((pass+1));;
  *)
    printf '  \033[31mFAIL\033[0m %-46s %s\n' "an oversized prompt answers, not hangs" "$OVER"; fail=$((fail+1));;
esac
wait_idle || true

echo
echo "== errors"
check "unknown model is 404" 404 "$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"model":"nope","messages":[{"role":"user","content":"x"}]}' "$BASE/v1/chat/completions")"
check "malformed body is 400" 400 "$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" -H 'Content-Type: application/json' -d '{ not json' "$BASE/v1/chat/completions")"

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
