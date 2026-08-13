#!/usr/bin/env bash
# test/identity_registry_test.sh — real HTTP-level regression test for
# OSOVM's cross-pillar identity registry (src/server.jl /v1/identity/*).
#
# This is a curl-based integration test, not a Julia unit test, because
# the registry only exists as HTTP endpoints on the running server --
# there's no in-process Julia function to call directly without
# spinning up the same HTTP server this test already drives.
#
# Requires: OSOVM server running and reachable (default localhost:7778).
set -euo pipefail

BASE="${OSOVM_HTTP_URL:-http://localhost:7778}"
FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc (expected $expected, got $actual)"
    FAIL=1
  else
    echo "PASS: $desc"
  fi
}

# --- Create a canonical identity, deterministic on seed+path ---
CID=$(curl -s -X POST "$BASE/v1/identity" -d '{"seed":"test-seed","path":"test/v1"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["canonical_id"])')
CID2=$(curl -s -X POST "$BASE/v1/identity" -d '{"seed":"test-seed","path":"test/v1"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["canonical_id"])')
check "same seed+path is deterministic (dedup)" "$CID" "$CID2"

# --- Link two different pillars to the same canonical identity ---
LINK1=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/identity/$CID/link" -d '{"pillar":"witness","pillar_id":"pubkey-abc"}')
check "link witness pillar" "200" "$LINK1"
LINK2=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/identity/$CID/link" -d '{"pillar":"sui","pillar_id":"0xdeadbeef"}')
check "link sui pillar" "200" "$LINK2"

# --- Forward lookup returns both pillars ---
GOT_WITNESS=$(curl -s "$BASE/v1/identity/$CID" | python3 -c 'import json,sys;print(json.load(sys.stdin)["pillars"]["witness"])')
check "forward lookup returns witness pillar_id" "pubkey-abc" "$GOT_WITNESS"

# --- Reverse lookup by pillar_id finds the canonical identity ---
REV_CID=$(curl -s "$BASE/v1/identity/lookup?pillar=witness&pillar_id=pubkey-abc" | python3 -c 'import json,sys;print(json.load(sys.stdin)["canonical_id"])')
check "reverse lookup finds canonical_id" "$CID" "$REV_CID"

# --- Hijack prevention: a DIFFERENT canonical identity cannot claim the same pillar_id ---
CID_OTHER=$(curl -s -X POST "$BASE/v1/identity" -d '{"seed":"other-seed","path":"test/v1"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["canonical_id"])')
HIJACK=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/identity/$CID_OTHER/link" -d '{"pillar":"witness","pillar_id":"pubkey-abc"}')
check "hijack attempt rejected" "409" "$HIJACK"

# --- Error paths ---
UNKNOWN_GET=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/identity/nonexistent")
check "unknown canonical_id returns 404" "404" "$UNKNOWN_GET"
UNKNOWN_LOOKUP=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/identity/lookup?pillar=witness&pillar_id=never-linked")
check "unlinked reverse lookup returns 404" "404" "$UNKNOWN_LOOKUP"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
